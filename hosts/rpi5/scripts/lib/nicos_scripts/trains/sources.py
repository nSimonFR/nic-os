"""Where the prices come from. Both sources are unofficial.

OUIGO: the JSON API behind ouigo.com, logged in with the web client's public
credentials (the same ones its own JS uses). TGV INOUI: 12train.com, a reseller
whose search form returns an HTML fragment. SNCF Connect itself is behind
DataDome and trvl's browser fallback for it is broken upstream (trvl #739).

Every fetch takes an `opener` (urlopen-shaped) so tests never touch the network.
"""

import http.cookiejar
import json
import re
import time
import unicodedata
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass

from ..httpjson import http_json
from ..secrets import env_str

OUIGO_API = "https://mdw.api-fr.ouigo.com/api"
OUIGO_HEADERS = {
    "Origin": "https://ventas.ouigo.com",
    "Accept-Language": "fr",
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0",
}
# Public web-client login, shipped in ouigo.com's own bundle — not a secret.
OUIGO_USER = "ouigo.web"
OUIGO_PASS = "SquirelWeb!2020"

T12_BASE = "https://www.12train.com"
T12_HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
    "Accept": "*/*",
    "Accept-Language": "fr-FR,fr;q=0.9",
    "Origin": T12_BASE,
    "Referer": f"{T12_BASE}/",
}
# One search returns ~6 trains from `hour` onward; these five cover a day.
T12_HOURS = (5, 9, 13, 17, 21)

SOURCES = ("ouigo", "inoui")


@dataclass(frozen=True)
class Journey:
    source: str
    departs: str  # YYYY-MM-DDTHH:MM, local
    arrives: str
    price: float | None  # cheapest 2nd class; None = sold out / not offered
    changes: int = 0
    train: str = ""

    def to_dict(self):
        return asdict(self)


def norm(text):
    """Accent- and case-insensitive key for station matching."""
    folded = unicodedata.normalize("NFKD", text or "")
    return "".join(c for c in folded if not unicodedata.combining(c)).casefold().strip()


# ---------------------------------------------------------------- OUIGO


class Ouigo:
    name = "ouigo"

    def __init__(self, opener=None):
        self.opener = opener
        self._token = None
        self._stations = None

    def _call(self, method, path, body=None):
        headers = dict(OUIGO_HEADERS)
        if path != "/Token/login":
            headers["Authorization"] = f"Bearer {self._login()}"
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(
            OUIGO_API + path, data=data, headers=headers, method=method
        )
        return http_json(req, opener=self.opener)

    def _login(self):
        if self._token is None:
            reply = self._call(
                "POST",
                "/Token/login",
                {"username": OUIGO_USER, "password": OUIGO_PASS},
            )
            self._token = reply["token"]
        return self._token

    def stations(self):
        if self._stations is None:
            self._stations = self._call("GET", "/Data/GetStations")
        return self._stations

    def station(self, query):
        """Station code for a name. "Paris" resolves to the all-stations group."""
        q = norm(query)
        stations = self.stations()
        pool = (
            [s for s in stations if norm(s["name"]) == q]
            or [s for s in stations if q in [norm(x) for x in s.get("synonyms") or []]]
            or [s for s in stations if q and q in norm(s["name"])]
        )
        if not pool:
            raise LookupError(f"gare OUIGO inconnue : {query}")
        pool.sort(key=lambda s: (not s.get("is_agglomeration"), bool(s.get("parent"))))
        return pool[0]["_u_i_c_station_code"]

    @staticmethod
    def _passengers():
        return [{"discount_cards": [], "disability_type": "NH", "type": "A"}]

    def search(self, origin, destination, date):
        reply = self._call(
            "POST",
            "/Sale/journeysearch",
            {
                "origin": self.station(origin),
                "destination": self.station(destination),
                "outbound_date": date,
                "passengers": self._passengers(),
                "with_ttt": False,
            },
        )
        out = []
        for t in reply.get("outbound") or []:
            dep = (t.get("departure_station") or {}).get("departure_timestamp")
            arr = (t.get("arrival_station") or {}).get("arrival_timestamp")
            if not dep or not arr:
                continue
            price = t.get("price")
            sold_out = t.get("full") or price is None
            out.append(
                Journey(
                    source=self.name,
                    departs=dep[:16],
                    arrives=arr[:16],
                    price=None if sold_out else float(price),
                    train=t.get("service_name") or "OUIGO",
                )
            )
        return out

    def calendar(self, origin, destination, start, end):
        """Lowest fare per day, [(date, price|None, is_promo)]. One call."""
        reply = self._call(
            "POST",
            "/Calendar/prices",
            {
                "origin": self.station(origin),
                "destination": self.station(destination),
                "begin": start,
                "end": end,
                "direction": "outbound",
                "passengers": self._passengers(),
            },
        )
        return [
            (
                d["date"][:10],
                None if d.get("price") is None else float(d["price"]),
                bool(d.get("is_promo")),
            )
            for d in reply
        ]


# ---------------------------------------------------------------- 12train


def _form(fields):
    """12train's PHP backend wants raw [] in keys and () in values."""
    return "&".join(
        f"{urllib.parse.quote(str(k), safe='[]')}={urllib.parse.quote(str(v), safe='()')}"
        for k, v in fields.items()
    ).encode()


def _amount(text):
    m = re.search(r"(\d+)\s*[,.]\s*(\d{2})", text)
    return float(f"{m.group(1)}.{m.group(2)}") if m else None


def _iso(stamp):
    """'28/11/2026 14:57' -> '2026-11-28T14:57'."""
    m = re.match(r"(\d{2})/(\d{2})/(\d{4}) (\d{2}:\d{2})", stamp or "")
    return f"{m.group(3)}-{m.group(2)}-{m.group(1)}T{m.group(4)}" if m else ""


def parse_12train(html):
    """Journeys from the `rail_search_results` fragment."""
    from bs4 import BeautifulSoup

    out = []
    for row in BeautifulSoup(html or "", "html.parser").select("div.r-s-r"):
        dep = _iso(row.get("data-rsrc_departure"))
        arr = _iso(row.get("data-rsrc_arrival"))
        if not dep or not arr:
            continue
        price = None
        for group in row.select(".r-s-r-travelclass-prices"):
            title = group.select_one(".r-s-r-travelclass-title")
            if not title or not title.get_text("", strip=True).startswith("2"):
                continue
            amounts = [
                a
                for el in group.select(".r-s-r-o-price-amount")
                if (a := _amount(el.get_text("", strip=True))) is not None
            ]
            price = min(amounts) if amounts else None
        duration = row.select_one(".j-p-result-j-duration")
        train = (
            re.search(r"en\s+(.+)", duration.get_text(" ", strip=True))
            if duration
            else None
        )
        out.append(
            Journey(
                source="inoui",
                departs=dep,
                arrives=arr,
                price=price,
                changes=max(0, len(row.select(".j-p-result-j-segment")) - 1),
                train=train.group(1) if train else "",
            )
        )
    return out


class Inoui:
    name = "inoui"

    def __init__(self, opener=None, sleep=time.sleep, hours=T12_HOURS):
        self.opener = (
            opener
            or urllib.request.build_opener(
                urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
            ).open
        )
        self.sleep = sleep
        self.hours = hours
        self._warm = False

    def _post(self, path, fields):
        req = urllib.request.Request(
            T12_BASE + path,
            data=_form(fields),
            headers={
                **T12_HEADERS,
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST",
        )
        return http_json(req, timeout=60, opener=self.opener)

    def _warm_up(self):
        # The PHPSESSID cookie; without it the form answers "Erreur technique".
        if not self._warm:
            self.opener(
                urllib.request.Request(T12_BASE, headers=T12_HEADERS), timeout=60
            ).close()
            self._warm = True

    def station(self, query):
        reply = self._post("/forms/form-station-autocomplete.php", {"term": query})
        labels = (
            [s["label"] for s in reply if isinstance(s, dict) and s.get("label")]
            if isinstance(reply, list)
            else []
        )
        if not labels:
            raise LookupError(f"gare 12train inconnue : {query}")
        return labels[0]

    def search(self, origin, destination, date):
        self._warm_up()
        self.sleep(1.0)
        o = self.station(origin)
        self.sleep(0.5)
        d = self.station(destination)
        y, m, day = date.split("-")
        seen = {}
        for hour in self.hours:
            self.sleep(0.5)
            reply = self._post(
                "/forms/form-sales-journey-planner-outward.php",
                {
                    "journey_planner_form_query_passengers[0][rank]": "1",
                    "journey_planner_form_query_passengers[0][sncf_age_group_code]": "59",
                    "journey_planner_form_query_passengers[0][cardNumber]": "",
                    "form[origin]": o,
                    "form[originCode]": "",
                    "form[destination]": d,
                    "form[destinationCode]": "",
                    "form[departure_date]": f"{day}/{m}/{y}",
                    "form[departure_hour]": str(hour).zfill(2),
                    "exchangeJourneyDirection": "oneway-outward",
                    "form[inward_date]": "",
                    "form[inward_hour]": "22",
                },
            )
            if reply.get("errors"):
                raise RuntimeError(
                    "12train : "
                    + "; ".join(e.get("message", "?") for e in reply["errors"])
                )
            html = (reply.get("search_results") or {}).get("rail_search_results", "")
            for j in parse_12train(html):
                seen[j.departs] = j
        return sorted(seen.values(), key=lambda j: j.departs)


def make_sources(env=None, opener=None):
    """{name: source}. TRAIN_WATCH_SOURCES narrows it (comma list)."""
    wanted = [
        s.strip()
        for s in env_str("TRAIN_WATCH_SOURCES", ",".join(SOURCES), env).split(",")
        if s.strip()
    ]
    built = {"ouigo": lambda: Ouigo(opener), "inoui": lambda: Inoui(opener)}
    return {n: built[n]() for n in wanted if n in built}
