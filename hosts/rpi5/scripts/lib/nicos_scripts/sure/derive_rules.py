"""Derive Sure `transaction_name = X` rules from the family's own history.

Sure asks an LLM to categorize every transaction it has no category for, and
that call is repeated on EVERY sync forever, because a refusal is never
recorded: `data_enrichments` stores successes only (0 null-valued rows in
5,377 on 2026-09-14). So a transaction the model cannot resolve is not a
one-off cost, it is a subscription. Measured on that date: `auto_detect_merchants`
had burned $105.09 over 21,966 calls, and a single harvest pass over the 540
merchant-less transactions resolved **0** of them.

The model is not malfunctioning. It is being asked questions it cannot answer:
`Steda`, `Vil Montorgueil`, `Mg St Ouen`, `Vkbfsceu`. No amount of prompting
makes a model know what a specific corner shop in Saint-Ouen is. But the user
already categorized those exact names, dozens of times. The answer is in the
database, not in the model.

So this mines the family's own categorized history for `name -> category` and
`name -> merchant` mappings and writes them as native Sure rules. That is a
durable fix rather than a periodic cleanup, because of how Sure's own scopes
compose:

  * `Rule::ActionExecutor::SetTransactionCategory` sets `category_id`, and
    `Family::AutoCategorizer#scope` filters `where(category_id: nil)` — so a
    rule-categorized row leaves the LLM's scope permanently. No lock needed.
  * `Family::Syncer#perform_post_sync` runs every active rule on every sync, so
    the NEXT `Mg St Ouen` is categorized deterministically, for free, before the
    LLM ever sees it.

Deliberately NOT done here:

- **Locking the residue.** What is left after these rules is genuinely
  unknowable — person-to-person payments whose category differs per
  transaction. Locking is a separate, reversible decision (`unlock_attr!`) and
  is not this script's business.
- **Blind `mode()` propagation.** The tempting query picks the most common
  category per name, but on this data that silently breaks ties: `Fannie
  Jacquemin` had SEVEN distinct categories across eight transactions, `Alfie`
  four across four. Those are people, paid for a different reason each time,
  and a rule would confidently apply a coin-flip. Hence `min_dominance`: a name
  only earns a rule when one answer actually dominates its history. On
  2026-09-14 that cut the candidate set from 43 names to 23 — the 20 it dropped
  were exactly the person-name payments.
- **A cron sweep.** An earlier design re-locked the residue monthly. Rules make
  that unnecessary: they run on every sync by construction, so new occurrences
  of a known name never accumulate in the first place.

`dry_run` defaults to True, so a Config built from an empty env cannot write.
"""

import sys
import uuid
from dataclasses import dataclass

from ..logs import logger
from ..secrets import env_int, env_str

TAG = "sure-derive-rules"

DEFAULT_SURE_DB = "sure_production"
DEFAULT_RUNUSER = "runuser"
DEFAULT_PSQL = "psql"
SEP = "\x1f"

# A name earns a rule only when one answer covers at least this share of its
# categorized history. 0.8 keeps "Boost" (31 of 45 Food & Drink) and rejects
# "Ethan Ohayon" (5 of 11 Food). Raising it to 1.0 would demand perfect
# consistency and drop names whose single stray miscategorization is itself the
# mistake the rule fixes.
DEFAULT_MIN_DOMINANCE = 0.8
# One observation is not a pattern. Two is the smallest claim that the name
# recurs at all, which is the whole premise of writing a rule for it.
DEFAULT_MIN_OBSERVATIONS = 2

# Sure's own rule shape, copied from the `Map "<name>" to <merchant>` rules the
# UI creates, so these are indistinguishable from hand-made ones and editable
# in the UI.
RESOURCE_TYPE = "transaction"
CONDITION_TYPE = "transaction_name"
CONDITION_OPERATOR = "="
ACTIONS = {
    "category": "set_transaction_category",
    "merchant": "set_transaction_merchant",
}


def _env_float(name, default, env=None):
    """Like `env_int`, for a ratio: garbage falls back rather than crashing."""
    try:
        return float(env_str(name, "", env).strip())
    except ValueError:
        return default


@dataclass(frozen=True)
class Config:
    db: str = DEFAULT_SURE_DB
    runuser: str = DEFAULT_RUNUSER
    psql: str = DEFAULT_PSQL
    family_id: str = ""
    min_dominance: float = DEFAULT_MIN_DOMINANCE
    min_observations: int = DEFAULT_MIN_OBSERVATIONS
    dry_run: bool = True

    @classmethod
    def from_env(cls, env=None):
        return cls(
            db=env_str("SURE_DB", DEFAULT_SURE_DB, env),
            runuser=env_str("RUNUSER_BIN", DEFAULT_RUNUSER, env),
            psql=env_str("PSQL_BIN", DEFAULT_PSQL, env),
            family_id=env_str("SURE_FAMILY_ID", "", env),
            min_dominance=_env_float("MIN_DOMINANCE", DEFAULT_MIN_DOMINANCE, env),
            min_observations=env_int("MIN_OBSERVATIONS", DEFAULT_MIN_OBSERVATIONS, env),
            # Safe by default: writing rules is the destructive direction, so a
            # Config built from an empty env cannot write.
            dry_run=env_str("APPLY", "", env).strip() not in ("1", "true", "yes"),
        )


def sql_literal(value):
    """Quote a Postgres string literal.

    Transaction names are bank-supplied and contain apostrophes (`Aux Saveurs
    D'ol`), so this cannot be skipped. NUL is rejected rather than stripped —
    Postgres cannot store it in text and a silent strip would change which
    transactions a rule matches.
    """
    if "\x00" in value:
        raise ValueError("NUL byte in SQL literal")
    return "'" + value.replace("'", "''") + "'"


# Candidate mappings: for every name that still has an unset target, the
# distribution of that target across the name's own history. Aggregating in SQL
# (rather than pulling rows) keeps this O(names) over the wire.
def candidates_sql(kind):
    column = "category_id" if kind == "category" else "merchant_id"
    # `kind` is not interpolated from user input — it selects a fixed column.
    unset_clause = "t.category_id IS NULL AND t.kind = 'standard'" \
        if kind == "category" else "t.merchant_id IS NULL"
    return f"""
        WITH hist AS (
          SELECT e.name, t.{column} AS target, COUNT(*) AS n
          FROM entries e
          JOIN transactions t ON t.id = e.entryable_id AND e.entryable_type = 'Transaction'
          WHERE t.{column} IS NOT NULL
          GROUP BY e.name, t.{column}
        ),
        ranked AS (
          SELECT name, target, n,
                 SUM(n) OVER (PARTITION BY name) AS total,
                 ROW_NUMBER() OVER (PARTITION BY name ORDER BY n DESC, target) AS rk
          FROM hist
        ),
        pending AS (
          SELECT DISTINCT e.name
          FROM entries e
          JOIN transactions t ON t.id = e.entryable_id AND e.entryable_type = 'Transaction'
          WHERE {unset_clause}
        )
        SELECT r.name, r.target::text, r.n::text, r.total::text,
               (SELECT COUNT(*) FROM entries e2
                  JOIN transactions t2 ON t2.id = e2.entryable_id
                   AND e2.entryable_type = 'Transaction'
                 WHERE e2.name = r.name AND {unset_clause.replace('t.', 't2.')})::text
        FROM ranked r
        JOIN pending p ON p.name = r.name
        WHERE r.rk = 1
        ORDER BY r.name
    """


def existing_rule_names_sql(kind):
    """Names already covered by a rule of this kind, so re-runs are no-ops."""
    return f"""
        SELECT DISTINCT c.value
        FROM rule_conditions c
        JOIN rules r ON r.id = c.rule_id
        JOIN rule_actions a ON a.rule_id = r.id
        WHERE c.condition_type = {sql_literal(CONDITION_TYPE)}
          AND a.action_type = {sql_literal(ACTIONS[kind])}
          AND c.value IS NOT NULL
    """


def select_mappings(rows, existing, min_dominance, min_observations):
    """Keep only names whose history gives one dominant, well-attested answer.

    Returns (accepted, rejected) where rejected carries a reason, so a dry run
    explains itself instead of silently shrinking.
    """
    accepted, rejected = [], []
    for name, target, top, total, pending in rows:
        top_n, total_n, pending_n = int(top), int(total), int(pending)
        dominance = top_n / total_n if total_n else 0.0
        if name in existing:
            rejected.append((name, "already has a rule", dominance, total_n))
        elif total_n < min_observations:
            rejected.append((name, f"only {total_n} observation(s)", dominance, total_n))
        elif dominance < min_dominance:
            rejected.append((name, f"ambiguous ({dominance:.0%})", dominance, total_n))
        else:
            accepted.append({
                "name": name, "target": target, "dominance": dominance,
                "observations": total_n, "pending": pending_n,
            })
    return accepted, rejected


def insert_sql(family_id, kind, mapping, new_uuid=None):
    """One rule + its condition + its action, as a single transaction."""
    new_uuid = new_uuid or (lambda: str(uuid.uuid4()))
    rule_id = new_uuid()
    label = f'Map "{mapping["name"]}" to {kind} (derived from history)'
    return (
        "BEGIN;\n"
        "INSERT INTO rules (id, family_id, name, resource_type, active, created_at, updated_at) "
        f"VALUES ({sql_literal(rule_id)}, {sql_literal(family_id)}, {sql_literal(label)}, "
        f"{sql_literal(RESOURCE_TYPE)}, true, now(), now());\n"
        "INSERT INTO rule_conditions (id, rule_id, condition_type, operator, value, created_at, updated_at) "
        f"VALUES (gen_random_uuid(), {sql_literal(rule_id)}, {sql_literal(CONDITION_TYPE)}, "
        f"{sql_literal(CONDITION_OPERATOR)}, {sql_literal(mapping['name'])}, now(), now());\n"
        "INSERT INTO rule_actions (id, rule_id, action_type, value, created_at, updated_at) "
        f"VALUES (gen_random_uuid(), {sql_literal(rule_id)}, {sql_literal(ACTIONS[kind])}, "
        f"{sql_literal(mapping['target'])}, now(), now());\n"
        "COMMIT;"
    )


def psql_rows(run, sql, cfg):
    out = run([cfg.runuser, "-u", "postgres", "--", cfg.psql,
               "-d", cfg.db, "-tAF" + SEP, "-c", sql])
    return [line.split(SEP) for line in out.splitlines() if line.strip()]


def psql_exec(run, sql, cfg):
    # ON_ERROR_STOP so a failed INSERT aborts instead of leaving a rule with no
    # action attached, which Sure would render as a rule that silently does
    # nothing.
    return run([cfg.runuser, "-u", "postgres", "--", cfg.psql,
                "-d", cfg.db, "-v", "ON_ERROR_STOP=1", "-c", sql])


def derive(run, cfg, family_id, kinds=("category", "merchant"), log=None,
           new_uuid=None):
    log = log or logger(TAG)
    created = 0
    for kind in kinds:
        rows = psql_rows(run, candidates_sql(kind), cfg)
        existing = {r[0] for r in psql_rows(run, existing_rule_names_sql(kind), cfg)}
        accepted, rejected = select_mappings(
            rows, existing, cfg.min_dominance, cfg.min_observations)

        covered = sum(m["pending"] for m in accepted)
        log(f"{kind}: {len(accepted)} rule(s) covering {covered} pending row(s); "
            f"{len(rejected)} name(s) skipped")
        for m in accepted:
            log(f"  + {m['name']!r} -> {m['target']} "
                f"({m['dominance']:.0%} of {m['observations']}, {m['pending']} pending)")
        for name, reason, _, _ in rejected:
            log(f"  - {name!r} skipped: {reason}")

        if cfg.dry_run:
            log(f"{kind}: DRY RUN, nothing written (set APPLY=1)")
            continue
        for m in accepted:
            psql_exec(run, insert_sql(family_id, kind, m, new_uuid), cfg)
            created += 1
    return created


def default_family_sql():
    """The family that owns the transactions, when one wasn't named.

    Picking by transaction count rather than `LIMIT 1`: Sure ships a demo
    family, and `Family.first` on this install is an EMPTY one — several past
    sessions burned time re-running enrichment against it and reading
    `{enhanced: 0}` as success.
    """
    return """
        SELECT a.family_id, COUNT(e.id)::text
        FROM accounts a
        JOIN entries e ON e.account_id = a.id
        GROUP BY a.family_id
        ORDER BY COUNT(e.id) DESC
        LIMIT 1
    """


def main(argv=None, env=None, run=None, log=None):
    import subprocess

    log = log or logger(TAG)
    cfg = Config.from_env(env)
    if run is None:
        def run(cmd):
            return subprocess.run(cmd, capture_output=True, text=True,
                                  check=True).stdout

    family_id = cfg.family_id
    if not family_id:
        rows = psql_rows(run, default_family_sql(), cfg)
        if not rows:
            log("FATAL: no family with transactions found")
            return 1
        family_id, tx_count = rows[0][0], rows[0][1]
        log(f"family {family_id} ({tx_count} entries)")

    created = derive(run, cfg, family_id, log=log)
    log("dry run — re-run with APPLY=1 to write" if cfg.dry_run
        else f"created {created} rule(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
