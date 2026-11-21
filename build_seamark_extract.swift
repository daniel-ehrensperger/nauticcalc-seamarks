// build_seamark_extract.swift
//
// Baut die Seezeichen-Dateien für das Briefing (#536): alle OSM-Objekte mit
// `seamark:*`-Tags (Leuchtfeuer, Tonnen, Brücken, Wracks, Felsen …), dazu
// Liegeplätze und Slipanlagen (#535), zerlegt in Zellen von 1° × 1°. Die
// App lädt beim Speichern eines Törns die Zellen, die die Route berührt, und
// hat sie danach offline.
//
// Warum Zellen statt benannter Reviere: Die App muss aus einer Route ohne
// Nachschlagetabelle ableiten können, welche Dateien sie braucht
// (`floor(lat)`, `floor(lon)`). Benannte Reviere haben Ränder, Überlappungen
// und Lücken dazwischen. Benannt sind nur die BAUGEBIETE in
// `seamark_areas.json`; sie legen fest, welche Zellen gebaut werden.
//
// Warum Overpass hier und nicht in der App: Die öffentlichen Server sind
// nicht für App-Verkehr gedacht, ihre Grenze gilt für alle Nutzer einer App
// zusammen. Dieses Skript schickt EINE Abfrage je Baugebiet, nacheinander,
// z. B. einmal pro Woche. Kein Gerät fragt Overpass.
//
// Welcher Server: NICHT overpass-api.de. Dessen Überlastseite (HTTP 502,
// 2026-11-19) sagt, der Server sei für Werkzeuge gedacht, die Menschen
// bedienen; automatisierte Nutzung soll eine eigene Instanz betreiben. Die
// Vorgabe ist ovp.dresel.systems: laut OSM-Wiki frei nutzbar ohne Schlüssel,
// höchstens 4 parallele Abfragen je IP, deckt aber NUR Europa und
// Nordamerika ab. Gebiete anderswo brauchen `--endpoint`. Auf Dauer
// unabhängig wäre ein Geofabrik-Auszug mit `osmium tags-filter` oder eine
// eigene Instanz. Overpass-Betreiber bitten um einen erkennbaren User-Agent:
// `--user-agent` bzw. `SEAMARK_USER_AGENT` setzen.
//
// ⚠️ Lücke ist nicht „nichts da": `index.json` führt JEDE gebaute Zelle,
// auch die mit 0 Objekten. Eine Zelle, die NICHT im Index steht, ist nicht
// abgedeckt — die App darf sie nie als „keine Seezeichen" anzeigen.
//
// ⚠️ Overpass meldet eine abgebrochene Abfrage (Zeitlimit, Speicher) mit
// HTTP 200 und einem `remark`, die Liste ist dann leer oder halb. Das Skript
// bricht in dem Fall ab, statt Löcher auszuliefern. Zusätzlich vergleicht es
// mit dem vorigen Index: Schrumpft eine Zelle mit mindestens 20 Objekten auf
// weniger als die Hälfte, schreibt es nichts (übersteuern mit `--force`).
//
// Lizenz: Die Dateien sind gefilterte, sonst unveränderte OSM-Daten und
// stehen unter ODbL 1.0. Wer sie ausliefert, muss sie öffentlich und
// kostenlos anbieten und „© OpenStreetMap contributors" nennen (#536,
// Abschnitt „Vorher klären"). Die Dateien nicht verschlüsseln (ODbL §4.7).
//
// Aufruf:
//   swift scripts/build_seamark_extract.swift \
//       --areas scripts/seamark_areas.json --out <Ausgabeordner> \
//       [--area <id>]… [--user-agent <Text>] [--endpoint <URL>] [--force] \
//       [--from-response <overpass.json>]
//
// `--from-response` liest eine gespeicherte Overpass-Antwort statt des Netzes
// (genau ein `--area` nötig) — für Prüfläufe ohne Server.
//
// Ausgabe:
//   <out>/index.json          alle gebauten Zellen mit Anzahl und Datenstand
//   <out>/cells/N54E010.json  Objekte einer Zelle (Süd-West-Ecke 54° N, 10° E)

import Foundation

// MARK: - Eingabe

struct Area: Decodable {
    let id: String
    let name: String
    /// Ganze Grad. Süd/West inklusive, Nord/Ost exklusive Zellgrenze.
    let south: Int
    let west: Int
    let north: Int
    let east: Int

    var cells: [Cell] {
        var result: [Cell] = []
        for lat in south..<north {
            for lon in west..<east { result.append(Cell(lat: lat, lon: lon)) }
        }
        return result
    }
}

struct Cell: Hashable, Comparable {
    /// Süd-West-Ecke in ganzen Grad.
    let lat: Int
    let lon: Int

    init(lat: Int, lon: Int) {
        self.lat = lat
        self.lon = lon
    }

    init(latitude: Double, longitude: Double) {
        self.init(lat: Int(latitude.rounded(.down)), lon: Int(longitude.rounded(.down)))
    }

    /// SRTM-Schreibweise: N54E010, S01W005 (S01 = Zelle von -1° bis 0°).
    var id: String {
        let ns = lat >= 0 ? "N" : "S"
        let ew = lon >= 0 ? "E" : "W"
        return ns + String(format: "%02d", abs(lat)) + ew + String(format: "%03d", abs(lon))
    }

    static func < (lhs: Cell, rhs: Cell) -> Bool {
        (lhs.lat, lhs.lon) < (rhs.lat, rhs.lon)
    }
}

struct Options {
    var areasPath: String?
    var outPath: String?
    var areaIDs: [String] = []
    var userAgent = ProcessInfo.processInfo.environment["SEAMARK_USER_AGENT"] ?? "seamark-extract-builder/1.0"
    var endpoint = "https://ovp.dresel.systems/api/interpreter"
    var force = false
    var responsePath: String?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Fehler: \(message)\n".utf8))
    exit(1)
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.dropFirst().makeIterator()
    func value(for flag: String) -> String {
        guard let next = iterator.next() else { fail("\(flag) braucht einen Wert") }
        return next
    }
    while let argument = iterator.next() {
        switch argument {
        case "--areas": options.areasPath = value(for: argument)
        case "--out": options.outPath = value(for: argument)
        case "--area": options.areaIDs.append(value(for: argument))
        case "--user-agent": options.userAgent = value(for: argument)
        case "--endpoint": options.endpoint = value(for: argument)
        case "--from-response": options.responsePath = value(for: argument)
        case "--force": options.force = true
        default: fail("unbekanntes Argument \(argument)")
        }
    }
    return options
}

func validate(_ areas: [Area]) {
    var owner: [Cell: String] = [:]
    var ids = Set<String>()
    for area in areas {
        guard ids.insert(area.id).inserted else { fail("Baugebiet \(area.id) doppelt") }
        guard area.south < area.north, area.west < area.east else {
            fail("Baugebiet \(area.id): Süd muss kleiner als Nord, West kleiner als Ost sein")
        }
        guard area.south >= -90, area.north <= 90, area.west >= -180, area.east <= 180 else {
            fail("Baugebiet \(area.id) liegt ausserhalb der Erde")
        }
        // Eine Zelle gehört genau einem Baugebiet — sonst überschreibt das
        // zweite die Datei des ersten mit einem anderen Datenstand.
        for cell in area.cells {
            if let other = owner[cell] { fail("Zelle \(cell.id) liegt in \(other) und \(area.id)") }
            owner[cell] = area.id
        }
    }
}

// MARK: - Overpass

struct OverpassResponse: Decodable {
    struct Meta: Decodable {
        let timestamp_osm_base: String
    }
    struct Bounds: Decodable {
        let minlat: Double
        let minlon: Double
        let maxlat: Double
        let maxlon: Double
    }
    struct Element: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let bounds: Bounds?
        let tags: [String: String]?
    }

    let osm3s: Meta
    let remark: String?
    let elements: [Element]
}

func query(for area: Area) -> String {
    // Alle Objekte tragen `seamark:type` (Kieler Bucht, 2026-11-19: 2 912 von
    // 2 912). Die zwei Licht-Zeilen fangen ein Feuer ohne Typ trotzdem auf.
    //
    // Die `leisure`-Zeile ist für #535 (Liegeplätze und Slipanlagen). Die
    // Sport-Kacheln von OpenSeaMap sind leer, deshalb kommen diese Objekte
    // aus OSM selbst. Gezählt am 2026-11-21: Liegeplätze tragen fast immer
    // auch `seamark:type=harbour` (Kiel 33 von 33, Zürichsee 68 von 72,
    // Bodensee 180 von 190). Slipanlagen dagegen oft nur `leisure=slipway`:
    // In der Kieler Bucht tragen 33 der 47 Slipanlagen kein einziges
    // `seamark:`-Tag. Ohne diese Zeile fehlten sie.
    //
    // Knoten mit `body` (Koordinaten), Linien/Relationen nur mit Hüllrechteck
    // — `body` würde für Linien sämtliche Knoten-IDs mitschicken.
    """
    [out:json][timeout:600][maxsize:1073741824][bbox:\(area.south),\(area.west),\(area.north),\(area.east)];
    (nwr["seamark:type"];nwr["seamark:light:character"];nwr["seamark:light:1:character"];nwr[leisure~"^(marina|slipway)$"];)->.all;
    node.all; out body;
    (way.all; relation.all;); out tags bb;
    """
}

func fetch(_ area: Area, options: Options) async -> Data {
    guard let url = URL(string: options.endpoint) else { fail("ungültiger Endpunkt \(options.endpoint)") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 900
    request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var form = URLComponents()
    form.queryItems = [URLQueryItem(name: "data", value: query(for: area))]
    // `+` bleibt in URLComponents stehen und hiesse im Formular „Leerzeichen".
    request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)

    // Verdoppelnde Pausen 30, 60, 120, 240 s (zusammen 7,5 min), wie es die
    // Fehlerseite von Overpass bei Überlast verlangt.
    let attempts = 5
    for attempt in 1...attempts {
        let pause = 30 << (attempt - 1)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return data }
            // 429 = Zeitfenster belegt, 502/503/504 = Server überlastet (am
            // 2026-11-19 kam 502 nach 0,6 s). Overpass verlangt mindestens
            // 30 s Pause vor dem nächsten Versuch.
            if status == 406 {
                fail("Overpass lehnt den User-Agent \"\(options.userAgent)\" ab (HTTP 406) — --user-agent setzen")
            }
            guard [429, 502, 503, 504].contains(status), attempt < attempts else {
                fail("Overpass antwortet für \(area.id) mit HTTP \(status)")
            }
            print("  HTTP \(status), neuer Versuch in \(pause) s")
        } catch {
            guard attempt < attempts else { fail("Overpass für \(area.id) nicht erreichbar: \(error.localizedDescription)") }
            print("  \(error.localizedDescription), neuer Versuch in \(pause) s")
        }
        try? await Task.sleep(nanoseconds: UInt64(pause) * 1_000_000_000)
    }
    fail("Overpass für \(area.id): kein Versuch erfolgreich")
}

// MARK: - Ausgabe

struct SeamarkObject: Encodable {
    /// `n123`, `w123`, `r123` — eindeutig und auf openstreetmap.org auffindbar.
    let osm: String
    let lat: Double
    let lon: Double
    /// Nur bei Linien/Relationen: [minLat, minLon, maxLat, maxLon].
    let bounds: [Double]?
    /// Nur `seamark:*`, `name` und `leisure=marina|slipway`, Werte
    /// unverändert aus OSM.
    let tags: [String: String]
}

struct CellFile: Encodable {
    let schema = 1
    let cell: String
    let south: Int
    let west: Int
    let north: Int
    let east: Int
    let osmBaseTimestamp: String
    let license = "ODbL-1.0"
    let attribution = "© OpenStreetMap contributors"
    let attributionURL = "https://www.openstreetmap.org/copyright"
    let objects: [SeamarkObject]
}

struct IndexFile: Codable {
    struct Entry: Codable {
        let cell: String
        let area: String
        let count: Int
        let osmBaseTimestamp: String
    }
    var schema = 1
    var cellSizeDegrees = 1
    var license = "ODbL-1.0"
    var attribution = "© OpenStreetMap contributors"
    var attributionURL = "https://www.openstreetmap.org/copyright"
    var source = "OpenStreetMap via Overpass API, gefiltert auf seamark:*, name und leisure=marina|slipway"
    var generatedAt: String
    var cells: [Entry]
}

/// Auf 7 Nachkommastellen — die Genauigkeit, mit der OSM Koordinaten speichert.
func round7(_ value: Double) -> Double {
    (value * 1e7).rounded() / 1e7
}

/// Die `leisure`-Werte, die der Auszug führt (#535). Ein `leisure=park` an
/// einer Bake gehört nicht hinein; nur, was die Abfrage auch gesucht hat.
let keptLeisureValues: Set<String> = ["marina", "slipway"]

func keptTags(_ tags: [String: String]?) -> [String: String] {
    (tags ?? [:]).filter {
        $0.key.hasPrefix("seamark:") || $0.key == "name"
            || ($0.key == "leisure" && keptLeisureValues.contains($0.value))
    }
}

/// Ordnet die Objekte den Zellen des Baugebiets zu. Linien landen in JEDER
/// Zelle, die ihr Hüllrechteck berührt (eine Brücke auf der Zellgrenze fehlt
/// sonst auf einer Seite); die App entdoppelt über `osm`.
func split(_ response: OverpassResponse, area: Area) -> [Cell: [SeamarkObject]] {
    let wanted = Set(area.cells)
    var result: [Cell: [SeamarkObject]] = Dictionary(uniqueKeysWithValues: area.cells.map { ($0, []) })
    let prefix = ["node": "n", "way": "w", "relation": "r"]

    for element in response.elements {
        let tags = keptTags(element.tags)
        guard !tags.isEmpty, let letter = prefix[element.type] else { continue }
        let osm = letter + String(element.id)

        if let lat = element.lat, let lon = element.lon {
            let cell = Cell(latitude: lat, longitude: lon)
            guard wanted.contains(cell) else { continue }
            result[cell, default: []].append(SeamarkObject(osm: osm, lat: lat, lon: lon, bounds: nil, tags: tags))
        } else if let b = element.bounds {
            let object = SeamarkObject(
                osm: osm,
                lat: round7((b.minlat + b.maxlat) / 2),
                lon: round7((b.minlon + b.maxlon) / 2),
                bounds: [b.minlat, b.minlon, b.maxlat, b.maxlon],
                tags: tags
            )
            let low = Cell(latitude: b.minlat, longitude: b.minlon)
            let high = Cell(latitude: b.maxlat, longitude: b.maxlon)
            for lat in low.lat...high.lat {
                for lon in low.lon...high.lon {
                    let cell = Cell(lat: lat, lon: lon)
                    if wanted.contains(cell) { result[cell, default: []].append(object) }
                }
            }
        }
    }
    for cell in result.keys {
        result[cell]?.sort { $0.osm < $1.osm }
    }
    return result
}

// MARK: - Ablauf

let options = parseOptions(CommandLine.arguments)
guard let areasPath = options.areasPath, let outPath = options.outPath else {
    fail("Aufruf: --areas <seamark_areas.json> --out <Ordner> [--area <id>]… [--force]")
}

let allAreas: [Area]
do {
    allAreas = try JSONDecoder().decode([Area].self, from: Data(contentsOf: URL(fileURLWithPath: areasPath)))
} catch {
    fail("\(areasPath) nicht lesbar: \(error)")
}
validate(allAreas)

var selected = options.areaIDs.isEmpty ? allAreas : []
for id in options.areaIDs {
    guard let area = allAreas.first(where: { $0.id == id }) else { fail("Baugebiet \(id) steht nicht in \(areasPath)") }
    selected.append(area)
}
if options.responsePath != nil, selected.count != 1 {
    fail("--from-response braucht genau ein --area")
}

let outURL = URL(fileURLWithPath: outPath)
let cellsURL = outURL.appendingPathComponent("cells")
let indexURL = outURL.appendingPathComponent("index.json")
let previous = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode(IndexFile.self, from: $0) }
let previousCount = Dictionary((previous?.cells ?? []).map { ($0.cell, $0.count) }, uniquingKeysWith: { a, _ in a })

// Erst alles holen und prüfen, dann schreiben: Bricht Gebiet 3 ab, bleiben
// die Dateien von Gebiet 1 und 2 auf dem alten, in sich stimmigen Stand.
var built: [(area: Area, timestamp: String, cells: [Cell: [SeamarkObject]])] = []
var shrunk: [String] = []

for (index, area) in selected.enumerated() {
    print("\(area.name) (\(area.id)): \(area.cells.count) Zellen")
    let data: Data
    if let responsePath = options.responsePath {
        guard let file = try? Data(contentsOf: URL(fileURLWithPath: responsePath)) else {
            fail("\(responsePath) nicht lesbar")
        }
        data = file
    } else {
        if index > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        data = await fetch(area, options: options)
    }

    let response: OverpassResponse
    do {
        response = try JSONDecoder().decode(OverpassResponse.self, from: data)
    } catch {
        let head = String(decoding: data.prefix(300), as: UTF8.self)
        fail("Antwort für \(area.id) ist kein Overpass-JSON: \(head)")
    }
    if let remark = response.remark {
        if remark.lowercased().contains("error") {
            fail("Overpass hat die Abfrage für \(area.id) abgebrochen, Daten unvollständig: \(remark)")
        }
        print("  Hinweis von Overpass: \(remark)")
    }

    let cells = split(response, area: area)
    let total = Set(cells.values.joined().map(\.osm)).count
    print("  \(total) Objekte, Datenstand \(response.osm3s.timestamp_osm_base)")

    for (cell, objects) in cells {
        guard let before = previousCount[cell.id], before >= 20 else { continue }
        if objects.count * 2 < before {
            shrunk.append("\(cell.id): \(before) → \(objects.count)")
        }
    }
    built.append((area, response.osm3s.timestamp_osm_base, cells))
}

if !shrunk.isEmpty {
    let list = shrunk.sorted().joined(separator: ", ")
    if options.force {
        print("Zellen stark geschrumpft, mit --force trotzdem geschrieben: \(list)")
    } else {
        fail("Zellen auf weniger als die Hälfte geschrumpft, nichts geschrieben (prüfen, dann --force): \(list)")
    }
}

do {
    try FileManager.default.createDirectory(at: cellsURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    var entries = Dictionary((previous?.cells ?? []).map { ($0.cell, $0) }, uniquingKeysWith: { a, _ in a })
    for (area, timestamp, cells) in built {
        // Einträge, die früher diesem Gebiet gehörten (z. B. vor einer
        // Verkleinerung), fallen weg — sonst gälte die Zelle als abgedeckt.
        entries = entries.filter { $0.value.area != area.id }
        for cell in cells.keys.sorted() {
            let objects = cells[cell] ?? []
            let file = CellFile(
                cell: cell.id, south: cell.lat, west: cell.lon, north: cell.lat + 1, east: cell.lon + 1,
                osmBaseTimestamp: timestamp, objects: objects
            )
            try encoder.encode(file).write(to: cellsURL.appendingPathComponent("\(cell.id).json"), options: .atomic)
            entries[cell.id] = IndexFile.Entry(cell: cell.id, area: area.id, count: objects.count, osmBaseTimestamp: timestamp)
        }
    }

    let formatter = ISO8601DateFormatter()
    let index = IndexFile(generatedAt: formatter.string(from: Date()), cells: entries.values.sorted { $0.cell < $1.cell })
    let pretty = JSONEncoder()
    pretty.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    // Index zuletzt: Er erst macht neue Zellen für die App sichtbar.
    try pretty.encode(index).write(to: indexURL, options: .atomic)
    print("Geschrieben: \(built.reduce(0) { $0 + $1.cells.count }) Zellen, Index mit \(index.cells.count) Zellen")
} catch {
    fail("Schreiben nach \(outPath) fehlgeschlagen: \(error)")
}
