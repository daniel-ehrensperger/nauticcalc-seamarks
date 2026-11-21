# Seezeichen-Zellen aus OpenStreetMap

Leuchtfeuer, Tonnen, Baken, Brücken, Liegeplätze und Slipanlagen aus
[OpenStreetMap](https://www.openstreetmap.org), gefiltert auf die Tags
`seamark:*`, `name` und `leisure=marina|slipway` und in Zellen von 1° × 1°
zerlegt. Gebaut einmal pro Woche von
[`build_seamark_extract.swift`](build_seamark_extract.swift) für die Gebiete in
[`seamark_areas.json`](seamark_areas.json).

Die App NauticCalc lädt diese Dateien, um im Törn-Briefing die Leuchtfeuer
entlang einer Route zu zeigen.

## Dateien

| Pfad | Inhalt |
|---|---|
| `index.json` | alle gebauten Zellen mit Anzahl der Objekte und OSM-Datenstand |
| `cells/N54E010.json` | die Objekte einer Zelle; der Name ist die Süd-West-Ecke (54° N, 10° E) |

Eine Zelle, die **nicht** im Index steht, ist nicht gebaut. Das heisst nicht,
dass es dort keine Seezeichen gibt.

## Lizenz

Die Daten sind © OpenStreetMap-Mitwirkende und stehen unter der
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).
Siehe [openstreetmap.org/copyright](https://www.openstreetmap.org/copyright).
Sie sind gefiltert, aber sonst unverändert: Tag-Namen und Werte stehen so in
den Dateien wie in OpenStreetMap.

Für das Skript gilt die Lizenz in [`LICENSE`](LICENSE).

## Keine Seekarte

Die Daten sind von Freiwilligen erfasst und können lückenhaft, veraltet oder
falsch sein. Sie ersetzen keine amtliche Seekarte und kein
Leuchtfeuerverzeichnis und sind nicht zur Navigation bestimmt.
