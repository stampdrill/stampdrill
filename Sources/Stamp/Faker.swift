import Foundation

/// Sample data for request bodies.
///
/// Everything is drawn from a `SeededRandom`, so with a seed the same values
/// come back every run. Records like `person` are built from one draw of the
/// generator, which keeps their fields consistent: the email matches the name.
public enum Faker {
    public static let members = [
        "id", "uuid", "number", "float", "bool",
        "firstName", "lastName", "name", "fullName", "username", "email", "phone", "avatar", "birthDate", "gender", "jobTitle",
        "company", "department", "product", "price", "currency", "iban", "creditCard", "color",
        "street", "city", "country", "countryCode", "zip", "latitude", "longitude",
        "word", "words", "sentence", "paragraph", "slug",
        "url", "domain", "ipv4", "ipv6", "mac", "userAgent",
        "date", "pastDate", "futureDate", "time", "timestamp",
        "person", "address", "organization",
    ]

    public static func value(_ member: String, using random: inout SeededRandom) -> Value? {
        switch member {
        case "id": return .number(Double(random.int(1...1_000_000)))
        case "uuid": return .string(random.uuid())
        case "number": return .number(Double(random.int(0...9999)))
        case "float": return .number((Double(random.int(0...1_000_000)) / 100).rounded(toPlaces: 2))
        case "bool": return .bool(random.int(0...1) == 1)

        case "firstName": return .string(random.pick(firstNames))
        case "lastName": return .string(random.pick(lastNames))
        case "name", "fullName": return .string(random.pick(firstNames) + " " + random.pick(lastNames))
        case "username": return person(using: &random).objectValue?["username"]
        case "email": return person(using: &random).objectValue?["email"]
        case "phone": return .string(phone(using: &random))
        case "avatar": return .string("https://i.pravatar.cc/300?u=\(random.int(1...99_999))")
        case "birthDate": return .string(date(daysFromNow: -random.int(18 * 365...80 * 365), using: &random, timeOfDay: false))
        case "gender": return .string(random.pick(["female", "male", "non-binary"]))
        case "jobTitle": return .string(random.pick(seniorities) + " " + random.pick(roles))

        case "company": return .string(companyName(using: &random))
        case "department": return .string(random.pick(departments))
        case "product": return .string(random.pick(adjectives).capitalized + " " + random.pick(products))
        case "price": return .number(Double(random.int(100...99_999)) / 100)
        case "currency": return .string(random.pick(["EUR", "USD", "GBP", "CHF", "SEK", "JPY"]))
        case "iban": return .string(iban(using: &random))
        case "creditCard": return .string(random.pick(["4242424242424242", "5555555555554444", "378282246310005", "6011111111111117"]))
        case "color": return .string(String(format: "#%06x", random.int(0...0xFFFFFF)))

        case "street": return .string("\(random.pick(streetNames)) \(random.pick(streetSuffixes)) \(random.int(1...240))")
        case "city": return .string(random.pick(cities).0)
        case "country": return .string(random.pick(cities).1)
        case "countryCode": return .string(random.pick(cities).2)
        case "zip": return .string(String(format: "%05d", random.int(1000...99_999)))
        case "latitude": return .number((Double(random.int(-90_000_000...90_000_000)) / 1_000_000))
        case "longitude": return .number((Double(random.int(-180_000_000...180_000_000)) / 1_000_000))

        case "word": return .string(random.pick(lorem))
        case "words": return .string((0..<random.int(2...5)).map { _ in random.pick(lorem) }.joined(separator: " "))
        case "sentence": return .string(sentence(using: &random))
        case "paragraph": return .string((0..<random.int(3...5)).map { _ in sentence(using: &random) }.joined(separator: " "))
        case "slug": return .string((0..<3).map { _ in random.pick(lorem) }.joined(separator: "-"))

        case "url": return .string("https://\(domain(using: &random))/\(random.pick(lorem))")
        case "domain": return .string(domain(using: &random))
        case "ipv4": return .string((0..<4).map { _ in String(random.int(1...254)) }.joined(separator: "."))
        case "ipv6": return .string((0..<8).map { _ in String(format: "%x", random.int(0...0xFFFF)) }.joined(separator: ":"))
        case "mac": return .string((0..<6).map { _ in String(format: "%02x", random.int(0...255)) }.joined(separator: ":"))
        case "userAgent": return .string(random.pick(userAgents))

        case "date": return .string(date(daysFromNow: random.int(-365...365), using: &random))
        case "pastDate": return .string(date(daysFromNow: -random.int(1...730), using: &random))
        case "futureDate": return .string(date(daysFromNow: random.int(1...730), using: &random))
        case "time": return .string(String(format: "%02d:%02d:%02d", random.int(0...23), random.int(0...59), random.int(0...59)))
        case "timestamp": return .number(Double(Int(Date().timeIntervalSince1970) + random.int(-31_536_000...31_536_000)))

        case "person": return person(using: &random)
        case "address": return address(using: &random)
        case "organization": return organization(using: &random)
        default: return nil
        }
    }

    // MARK: Records

    public static func person(using random: inout SeededRandom) -> Value {
        let first = random.pick(firstNames)
        let last = random.pick(lastNames)
        let handle = (first + "." + last).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0 == "." }
        let id = random.int(1...999_999)
        return [
            "id": .number(Double(id)),
            "firstName": .string(first),
            "lastName": .string(last),
            "name": .string(first + " " + last),
            "username": .string(handle.replacingOccurrences(of: ".", with: "") + String(random.int(1...99))),
            "email": .string(handle + "@" + random.pick(emailDomains)),
            "phone": .string(phone(using: &random)),
            "birthDate": .string(date(daysFromNow: -random.int(18 * 365...80 * 365), using: &random, timeOfDay: false)),
            "avatar": .string("https://i.pravatar.cc/300?u=\(id)"),
            "jobTitle": .string(random.pick(seniorities) + " " + random.pick(roles)),
            "address": address(using: &random),
        ]
    }

    public static func address(using random: inout SeededRandom) -> Value {
        let place = random.pick(cities)
        return [
            "street": .string("\(random.pick(streetNames)) \(random.pick(streetSuffixes)) \(random.int(1...240))"),
            "city": .string(place.0),
            "zip": .string(String(format: "%05d", random.int(1000...99_999))),
            "country": .string(place.1),
            "countryCode": .string(place.2),
        ]
    }

    public static func organization(using random: inout SeededRandom) -> Value {
        let name = companyName(using: &random)
        let slug = name.lowercased().filter { $0.isLetter }
        return [
            "id": .number(Double(random.int(1...999_999))),
            "name": .string(name),
            "domain": .string(slug + ".example"),
            "email": .string("hello@" + slug + ".example"),
            "industry": .string(random.pick(industries)),
            "employees": .number(Double(random.int(3...20_000))),
            "address": address(using: &random),
        ]
    }

    // MARK: Pieces

    private static func phone(using random: inout SeededRandom) -> String {
        "+\(random.pick(["1", "31", "44", "46", "49", "90", "964"])) \(random.int(100...999)) \(random.int(100...999)) \(random.int(1000...9999))"
    }

    private static func companyName(using random: inout SeededRandom) -> String {
        random.pick(lastNames) + " " + random.pick(companySuffixes)
    }

    private static func domain(using random: inout SeededRandom) -> String {
        random.pick(lorem) + random.pick(lorem) + "." + random.pick(["com", "io", "dev", "org", "example"])
    }

    private static func sentence(using random: inout SeededRandom) -> String {
        let words = (0..<random.int(6...12)).map { _ in random.pick(lorem) }.joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst() + "."
    }

    private static func iban(using random: inout SeededRandom) -> String {
        let country = random.pick(["DE", "NL", "FR", "ES", "SE"])
        let digits = (0..<18).map { _ in String(random.int(0...9)) }.joined()
        return country + String(format: "%02d", random.int(10...98)) + digits
    }

    private static func date(daysFromNow days: Int, using random: inout SeededRandom, timeOfDay: Bool = true) -> String {
        let reference = Calendar(identifier: .gregorian).startOfDay(for: Date())
        let seconds = timeOfDay ? random.int(0...86_399) : 0
        let date = reference.addingTimeInterval(Double(days * 86_400 + seconds))
        return timeOfDay ? date.formatted(.iso8601) : date.formatted(.iso8601.year().month().day())
    }

    // MARK: Tables

    static let firstNames = [
        "Rojîn", "Aram", "Emily", "Michael", "Sophia", "Lucas", "Amara", "Kenji", "Leila", "Mateo", "Noor", "Oskar",
        "Priya", "Samir", "Hana", "Elif", "Jonas", "Maya", "Diego", "Zara", "Ibrahim", "Freya", "Yusuf", "Chloé",
    ]
    static let lastNames = [
        "Maroufi", "Johnson", "Williams", "Brown", "Andersson", "Tanaka", "Haddad", "García", "Nguyen", "Kaya",
        "Schmidt", "Rossi", "Okafor", "Novak", "Dubois", "Kowalski", "Silva", "Ahmadi", "Larsen", "Müller",
    ]
    static let emailDomains = ["example.com", "mail.example", "inbox.example", "stampdrill.dev"]
    static let seniorities = ["Junior", "Senior", "Lead", "Principal", "Staff", "Head of"]
    static let roles = ["Engineer", "Designer", "Product Manager", "Data Analyst", "Support Specialist", "Researcher", "Accountant"]
    static let departments = ["Engineering", "Design", "Marketing", "Sales", "Finance", "Support", "Operations"]
    static let companySuffixes = ["Labs", "Studios", "Group", "Systems", "& Co", "Logistics", "Foods", "Software"]
    static let industries = ["Retail", "Healthcare", "Logistics", "Education", "Finance", "Media", "Energy"]
    static let adjectives = ["compact", "wireless", "organic", "ergonomic", "vintage", "smart", "handmade", "recycled"]
    static let products = ["Lamp", "Backpack", "Headphones", "Notebook", "Teapot", "Chair", "Keyboard", "Bicycle"]
    static let streetNames = ["Oak", "Linden", "Harbor", "Mill", "Rose", "Station", "Market", "Willow", "Cedar"]
    static let streetSuffixes = ["Street", "Avenue", "Lane", "Road", "Way", "Square"]
    static let cities: [(String, String, String)] = [
        ("Berlin", "Germany", "DE"), ("Amsterdam", "Netherlands", "NL"), ("Stockholm", "Sweden", "SE"),
        ("Erbil", "Iraq", "IQ"), ("Istanbul", "Türkiye", "TR"), ("Lisbon", "Portugal", "PT"), ("Tokyo", "Japan", "JP"),
        ("Toronto", "Canada", "CA"), ("São Paulo", "Brazil", "BR"), ("Nairobi", "Kenya", "KE"), ("Austin", "United States", "US"),
    ]
    static let lorem = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", "eiusmod", "tempor",
        "incididunt", "labore", "dolore", "magna", "aliqua", "enim", "minim", "veniam", "quis", "nostrud", "exercitation",
        "ullamco", "laboris", "nisi", "aliquip", "commodo", "consequat", "letter", "parcel", "stamp", "courier",
    ]
    static let userAgents = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "curl/8.7.1",
    ]
}


extension Double {
    public func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
