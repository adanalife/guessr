import AppIntents

/// A US state, as Siri hears it: a closed list is what lets a phrase carry the
/// guess ("guess Texas in …") rather than asking for it after. The raw value is
/// what `!guess` is sent with.
enum USState: String, AppEnum {
    case alabama = "Alabama"
    case alaska = "Alaska"
    case arizona = "Arizona"
    case arkansas = "Arkansas"
    case california = "California"
    case colorado = "Colorado"
    case connecticut = "Connecticut"
    case delaware = "Delaware"
    case florida = "Florida"
    case georgia = "Georgia"
    case hawaii = "Hawaii"
    case idaho = "Idaho"
    case illinois = "Illinois"
    case indiana = "Indiana"
    case iowa = "Iowa"
    case kansas = "Kansas"
    case kentucky = "Kentucky"
    case louisiana = "Louisiana"
    case maine = "Maine"
    case maryland = "Maryland"
    case massachusetts = "Massachusetts"
    case michigan = "Michigan"
    case minnesota = "Minnesota"
    case mississippi = "Mississippi"
    case missouri = "Missouri"
    case montana = "Montana"
    case nebraska = "Nebraska"
    case nevada = "Nevada"
    case newHampshire = "New Hampshire"
    case newJersey = "New Jersey"
    case newMexico = "New Mexico"
    case newYork = "New York"
    case northCarolina = "North Carolina"
    case northDakota = "North Dakota"
    case ohio = "Ohio"
    case oklahoma = "Oklahoma"
    case oregon = "Oregon"
    case pennsylvania = "Pennsylvania"
    case rhodeIsland = "Rhode Island"
    case southCarolina = "South Carolina"
    case southDakota = "South Dakota"
    case tennessee = "Tennessee"
    case texas = "Texas"
    case utah = "Utah"
    case vermont = "Vermont"
    case virginia = "Virginia"
    case washington = "Washington"
    case westVirginia = "West Virginia"
    case wisconsin = "Wisconsin"
    case wyoming = "Wyoming"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "State"
    static let caseDisplayRepresentations: [USState: DisplayRepresentation] = [
        .alabama: "Alabama",
        .alaska: "Alaska",
        .arizona: "Arizona",
        .arkansas: "Arkansas",
        .california: "California",
        .colorado: "Colorado",
        .connecticut: "Connecticut",
        .delaware: "Delaware",
        .florida: "Florida",
        .georgia: "Georgia",
        .hawaii: "Hawaii",
        .idaho: "Idaho",
        .illinois: "Illinois",
        .indiana: "Indiana",
        .iowa: "Iowa",
        .kansas: "Kansas",
        .kentucky: "Kentucky",
        .louisiana: "Louisiana",
        .maine: "Maine",
        .maryland: "Maryland",
        .massachusetts: "Massachusetts",
        .michigan: "Michigan",
        .minnesota: "Minnesota",
        .mississippi: "Mississippi",
        .missouri: "Missouri",
        .montana: "Montana",
        .nebraska: "Nebraska",
        .nevada: "Nevada",
        .newHampshire: "New Hampshire",
        .newJersey: "New Jersey",
        .newMexico: "New Mexico",
        .newYork: "New York",
        .northCarolina: "North Carolina",
        .northDakota: "North Dakota",
        .ohio: "Ohio",
        .oklahoma: "Oklahoma",
        .oregon: "Oregon",
        .pennsylvania: "Pennsylvania",
        .rhodeIsland: "Rhode Island",
        .southCarolina: "South Carolina",
        .southDakota: "South Dakota",
        .tennessee: "Tennessee",
        .texas: "Texas",
        .utah: "Utah",
        .vermont: "Vermont",
        .virginia: "Virginia",
        .washington: "Washington",
        .westVirginia: "West Virginia",
        .wisconsin: "Wisconsin",
        .wyoming: "Wyoming",
    ]

    /// The name in the device's language, for a label; `rawValue` is what
    /// `!guess` sends, in English, since the bot reads that.
    var localizedName: String {
        Self.caseDisplayRepresentations[self].map { String(localized: $0.title) } ?? rawValue
    }

    /// By postal code, the form a reverse geocode usually names the state in.
    static let abbreviations: [String: USState] = [
        "AL": .alabama,
        "AK": .alaska,
        "AZ": .arizona,
        "AR": .arkansas,
        "CA": .california,
        "CO": .colorado,
        "CT": .connecticut,
        "DE": .delaware,
        "FL": .florida,
        "GA": .georgia,
        "HI": .hawaii,
        "ID": .idaho,
        "IL": .illinois,
        "IN": .indiana,
        "IA": .iowa,
        "KS": .kansas,
        "KY": .kentucky,
        "LA": .louisiana,
        "ME": .maine,
        "MD": .maryland,
        "MA": .massachusetts,
        "MI": .michigan,
        "MN": .minnesota,
        "MS": .mississippi,
        "MO": .missouri,
        "MT": .montana,
        "NE": .nebraska,
        "NV": .nevada,
        "NH": .newHampshire,
        "NJ": .newJersey,
        "NM": .newMexico,
        "NY": .newYork,
        "NC": .northCarolina,
        "ND": .northDakota,
        "OH": .ohio,
        "OK": .oklahoma,
        "OR": .oregon,
        "PA": .pennsylvania,
        "RI": .rhodeIsland,
        "SC": .southCarolina,
        "SD": .southDakota,
        "TN": .tennessee,
        "TX": .texas,
        "UT": .utah,
        "VT": .vermont,
        "VA": .virginia,
        "WA": .washington,
        "WV": .westVirginia,
        "WI": .wisconsin,
        "WY": .wyoming,
    ]
}
