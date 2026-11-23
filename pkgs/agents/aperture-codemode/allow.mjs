// Allowlist for upstream tools: comma-separated `pattern[:action|action]` entries, `*` as a
// wildcard. With actions, only calls whose `action` input is listed pass (multi-action tools
// such as Datadog's mix reads and writes). An empty list allows everything.

const toRegExp = (glob) =>
  new RegExp(`^${glob.split("*").map((s) => s.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`);

export function parseAllow(spec = "") {
  return spec
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((entry) => {
      const [glob, actions] = entry.split(":");
      return { re: toRegExp(glob.trim()), actions: actions ? new Set(actions.split("|").map((a) => a.trim())) : null };
    });
}

export class Allow {
  constructor(spec) {
    this.rules = parseAllow(spec);
  }

  get empty() {
    return this.rules.length === 0;
  }

  /** @returns {null | Set<string> | true} null: refused; Set: allowed actions; true: any input */
  rule(name) {
    if (this.empty) return true;
    let actions = null;
    for (const r of this.rules) {
      if (!r.re.test(name)) continue;
      if (!r.actions) return true;
      actions = new Set([...(actions ?? []), ...r.actions]);
    }
    return actions;
  }

  allows(name) {
    return this.rule(name) !== null;
  }

  /** Throws unless this call is allowed. */
  check(name, input) {
    const rule = this.rule(name);
    if (rule === null) throw new Error(`${name} is not allowed here (read-only allowlist)`);
    if (rule !== true && !rule.has(input?.action)) {
      throw new Error(`${name} action "${input?.action}" is not allowed here; allowed: ${[...rule].join(", ")}`);
    }
  }

  /** Narrows an `action` enum in the input schema to the allowed actions, for the declarations. */
  narrow(name, schema) {
    const rule = this.rule(name);
    const action = schema?.properties?.action;
    if (rule === true || rule === null || !action) return schema;
    const allowed = Array.isArray(action.enum) ? action.enum.filter((a) => rule.has(a)) : [...rule];
    return { ...schema, properties: { ...schema.properties, action: { ...action, enum: allowed } } };
  }
}
