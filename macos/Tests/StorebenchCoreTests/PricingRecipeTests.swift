import Foundation
import Testing
@testable import StorebenchCore

@Suite struct PricingRecipeTests {
    init() throws { _ = try TestIsolation.require() }

    func rate(_ value: String) -> FxRate { FxRate(rate: value, date: "2026-03-01", source: "frankfurter", providers: nil, fetchedAt: nil) }
    let countries = [Territory(code: "USA", name: "United States", currency: "USD"), Territory(code: "SWE", name: "Sweden", currency: "SEK"), Territory(code: "NOR", name: "Norway", currency: "NOK")]

    @Test func aRecipeMixesMethodsScalesCountriesAndKeepsPricesWithinItsLimits() throws {
        let recipe = try PricingProfile(id: "recipe", name: "Synthetic recipe", guideTerritory: "USA", rounding: "nearest", method: "ppp", percentages: ["SWE": 90],
                                        mix: PricingMix(method: "fx", share: 25), floor: 80, ceiling: 110).validated()
        let index = IndexSnapshot(method: "ppp", date: "2025", source: "World Bank PA.NUS.PPP", values: ["USA": "1", "SWE": "8", "NOR": "12"])
        let points = [("USA", "9.99"), ("USA", "10.99"), ("SWE", "79"), ("SWE", "80"), ("SWE", "85"), ("NOR", "109"), ("NOR", "110")].enumerated().map { PricePoint(id: "p\($0.offset)", territory: $0.element.0, customerPrice: $0.element.1) }
        let rows = try PricingModels.calculate(recipe, base: "10", countries: countries, guideCurrency: "USD", rates: ["SEK": rate("10"), "NOK": rate("10")], points: points, indexes: [index])
        // Sweden: 75% of 80 SEK by purchasing power and 25% of 100 SEK by exchange rate is 85, 90% of that is 76.5, raised to 80% of 100 SEK.
        #expect(rows.first { $0.territory == "SWE" }?.calculated == "80" && rows.first { $0.territory == "SWE" }?.amount == "80")
        // Norway: 75% of 120 and 25% of 100 is 115, lowered to 110% of 100 NOK.
        #expect(rows.first { $0.territory == "NOR" }?.calculated == "110" && rows.first { $0.territory == "NOR" }?.amount == "110")
        #expect(rows.first { $0.territory == "USA" }?.calculated == "10" && rows.first { $0.territory == "USA" }?.amount == "9.99")
        let detail = try #require(rows.first { $0.territory == "SWE" }?.detail)
        #expect(detail.contains("Mixed 25% Currency conversion") && detail.contains("Country percentage: 90%") && detail.contains("Raised to the lowest price"))
        // Limits need exchange rates even for an index method alone.
        var noMix = recipe; noMix.mix = nil
        let plain = try PricingProfile(id: "p", name: "P", guideTerritory: "USA", rounding: "nearest", method: "ppp", percentages: [:]).validated()
        #expect(noMix.needsExchangeRates && !plain.needsExchangeRates)
        let missing = try PricingModels.calculate(noMix, base: "10", countries: countries, guideCurrency: "USD", rates: [:], points: points, indexes: [index])
        #expect(missing.first { $0.territory == "SWE" }?.problem?.contains("lowest and highest price") == true)
    }

    @Test func theChosenApplePricePointStaysWithinTheLowestAndHighestPrice() throws {
        // At 10 SEK and NOK per USD, 10 USD converts to 100. Sweden lands below its lowest price of 80, Norway above its highest of 110.
        // Exact keeps the limited amount itself rather than an Apple price point.
        let points = [("USA", "9.99"), ("SWE", "79"), ("SWE", "85"), ("NOR", "105"), ("NOR", "112")].enumerated().map { PricePoint(id: "p\($0.offset)", territory: $0.element.0, customerPrice: $0.element.1) }
        let rates = ["SEK": rate("10"), "NOK": rate("10")]
        let expected: [(String, String?, String?)] = [("nearest", "85", "105"), ("up", "85", nil), ("down", nil, "105"), ("exact", "80", "110")]
        for (rounding, sweden, norway) in expected {
            let recipe = try PricingProfile(id: "r", name: "Limits", guideTerritory: "USA", rounding: rounding, method: "fx", percentages: ["SWE": 70, "NOR": 130], floor: 80, ceiling: 110).validated()
            let rows = try PricingModels.calculate(recipe, base: "10", countries: countries, guideCurrency: "USD", rates: rates, points: points, indexes: [])
            let swe = try #require(rows.first { $0.territory == "SWE" }), nor = try #require(rows.first { $0.territory == "NOR" })
            #expect(swe.calculated == "80" && swe.amount == sweden, "\(rounding) Sweden")
            #expect(nor.calculated == "110" && nor.amount == norway, "\(rounding) Norway")
            for row in [swe, nor] {
                if let amount = row.amount.flatMap(PricingMath.decimal) { #expect(amount >= 80 && amount <= 110) }
                else { #expect(row.pointStatus == "unavailable" && row.problem != nil) }
            }
        }
        let down = try PricingProfile(id: "r", name: "Limits", guideTerritory: "USA", rounding: "down", method: "fx", percentages: ["SWE": 70], floor: 80, ceiling: 110).validated()
        let sweden = try #require(try PricingModels.calculate(down, base: "10", countries: countries, guideCurrency: "USD", rates: rates, points: points, indexes: []).first { $0.territory == "SWE" })
        #expect(sweden.problem == "No Apple price point lies between the lowest and highest price." && sweden.detail.contains("No Apple price point lies between"))
        // A range with no Apple price point inside it leaves the country without a price.
        let narrow = try PricingProfile(id: "n", name: "Narrow", guideTerritory: "USA", rounding: "nearest", method: "fx", percentages: [:], floor: 86, ceiling: 88).validated()
        let none = try #require(try PricingModels.calculate(narrow, base: "10", countries: countries, guideCurrency: "USD", rates: rates, points: points, indexes: []).first { $0.territory == "SWE" })
        #expect(none.amount == nil && none.problem == "No Apple price point lies between the lowest and highest price.")
    }

    @Test func yourOwnIndexScalesByEachCountrysValueAgainstTheGuideCountry() throws {
        let own = try PricingProfile(id: "own", name: "Synthetic index", guideTerritory: "USA", rounding: "nearest", method: "own", percentages: [:], index: ["USA": 10, "SWE": 50]).validated()
        let points = [PricePoint(id: "a", territory: "USA", customerPrice: "4.99"), PricePoint(id: "b", territory: "SWE", customerPrice: "25")]
        let rows = try PricingModels.calculate(own, base: "4.99", countries: countries, guideCurrency: "USD", rates: [:], points: points, indexes: [])
        #expect(rows.first { $0.territory == "SWE" }?.calculated == "24.95" && rows.first { $0.territory == "SWE" }?.amount == "25")
        #expect(rows.first { $0.territory == "NOR" }?.problem == "Index data unavailable for this country or guide country.")
        #expect(rows.first { $0.territory == "SWE" }?.detail.hasPrefix("Your own index · Local price ratio: 5") == true)
    }

    @Test func recipesAreValidatedBeforeTheyAreSaved() throws {
        func profile(_ method: String, mix: PricingMix? = nil, floor: Double? = nil, ceiling: Double? = nil, index: [String: Double] = [:]) -> PricingProfile {
            PricingProfile(id: "p", name: "P", guideTerritory: "USA", rounding: "nearest", method: method, percentages: [:], mix: mix, floor: floor, ceiling: ceiling, index: index)
        }
        for invalid in [profile("ppp", mix: PricingMix(method: "ppp", share: 30)), profile("ppp", mix: PricingMix(method: "same", share: 30)), profile("custom", mix: PricingMix(method: "fx", share: 30)),
                        profile("ppp", mix: PricingMix(method: "fx", share: 100)), profile("fx", floor: 120, ceiling: 80), profile("same", floor: 50), profile("fx", ceiling: 0),
                        profile("own", index: ["SWE": 50]), profile("fx", mix: PricingMix(method: "own", share: 20), index: ["SWE": 2]), profile("own", index: ["USA": 0])] {
            #expect(throws: PricingFailure.self) { try invalid.validated() }
        }
        let checked = try profile("fx", mix: PricingMix(method: "own", share: 20.5), floor: 30, ceiling: 150, index: ["usa": 1, "SWE": 9]).validated()
        #expect(checked.index == ["USA": 1, "SWE": 9] && checked.mix == PricingMix(method: "own", share: 20.5) && checked.summary.contains("20.5% comes from Your own index"))
    }

    @Test func oldProfilesKeepTheirStoredFormAndRecipesRoundTrip() throws {
        let stored = JSONText.object([("id", .string("standard")), ("name", .string("Standard")), ("guideTerritory", .string("USA")), ("rounding", .string("nearest")), ("method", .string("custom")),
                                      ("percentages", .object([("SWE", .number(85.5))]))])
        let old = try #require(PricingProfile(stored))
        #expect(old.mix == nil && old.floor == nil && old.ceiling == nil && old.index.isEmpty)
        #expect(PricingModels.profileRevision(old) == PricingModels.revision(stored))
        let recipe = try PricingProfile(id: "r", name: "Recipe", guideTerritory: "USA", rounding: "up", method: "bigmac", percentages: ["SWE": 95], mix: PricingMix(method: "fx", share: 40), floor: 50, ceiling: 200).validated()
        #expect(PricingProfile(recipe.json) == recipe)
        // An app's own model saved before recipes only has a method, rounding and percentages.
        let applied = try #require(recipe.applying(recipe: .object([("method", .string("fx")), ("rounding", .string("down")), ("percentages", .object([]))])))
        #expect(applied.method == "fx" && applied.mix == nil && applied.floor == nil && applied.id == "r" && applied.guideTerritory == "USA")
        #expect(recipe.applying(recipe: recipe.recipeJSON) == recipe)
    }

    @Test func changingTheMethodDropsAMixItCannotUseAndKeepsOtherInputs() throws {
        let start = PricingProfileInputs(try PricingProfile(id: "p", name: "Synthetic", guideTerritory: "USA", rounding: "nearest", method: "ppp", percentages: ["SWE": 90],
                                                            mix: PricingMix(method: "fx", share: 25), floor: 80).validated())
        #expect(start.mixMethod == "fx" && start.effectiveMixMethod == "fx")
        for (method, keepsMix) in [("same", false), ("custom", false), ("fx", false), ("bigmac", true)] {
            var inputs = start; inputs.name = "Unsaved synthetic name"
            inputs.choose(method: method)
            #expect(inputs.method == method && (inputs.mixMethod == "fx") == keepsMix && inputs.name == "Unsaved synthetic name" && inputs.floor == start.floor, "\(method)")
            #expect(inputs.mixShare == start.mixShare && inputs.overrides == start.overrides && inputs.rounding == start.rounding)
            // Saving uses the same recipe the form shows: no hidden mix blocks it.
            let saved = try inputs.validated()
            #expect((saved.mix != nil) == keepsMix, "\(method)")
        }
        // A mix left in place by other code is still ignored when the method cannot use it.
        var direct = start; direct.method = "same"
        let directSaved = try direct.validated()
        #expect(direct.effectiveMixMethod.isEmpty && directSaved.mix == nil)
    }

    @Test func anInactiveOwnIndexDoesNotBlockSavingAnotherMethod() throws {
        var inputs = PricingProfileInputs(PricingProfile(id: "synthetic", name: "Synthetic", guideTerritory: "USA", rounding: "nearest", method: "same", percentages: [:]))
        inputs.mixMethod = "own"; inputs.mixShare = "unfinished"
        inputs.indexRows = [.init(territory: "USA", percentage: "unfinished")]
        #expect(!inputs.usesOwnIndex)
        let saved = try inputs.validated()
        #expect(saved.mix == nil && saved.index.isEmpty && saved.method == "same")
        // The same index is required when it is part of the effective recipe.
        inputs.method = "fx"; inputs.mixShare = "25"
        #expect(inputs.usesOwnIndex)
        #expect(throws: PricingFailure.self) { try inputs.validated() }
    }

    @Test func editorInputsKeepRecipeTextUntilTheyAreValidated() throws {
        var inputs = PricingProfileInputs(PricingProfile(id: "p", name: "P", guideTerritory: "USA", rounding: "nearest", method: "ppp", percentages: [:]))
        #expect(inputs.mixMethod.isEmpty && inputs.floor.isEmpty && inputs.indexRows.isEmpty)
        inputs.mixMethod = "own"; inputs.mixShare = "x"
        #expect(throws: PricingFailure.self) { try inputs.validated() }
        inputs.mixShare = "35"; inputs.floor = "40"; inputs.ceiling = ""
        inputs.indexRows = PricingProfileInputs.merge([.init(territory: "SWE", percentage: "1")], ["SWE": "9", "USA": "1"])
        let profile = try inputs.validated()
        #expect(profile.mix == PricingMix(method: "own", share: 35) && profile.floor == 40 && profile.ceiling == nil && profile.index == ["SWE": 9, "USA": 1])
        #expect(PricingProfileInputs(profile) == inputs)
        inputs.method = "same"; inputs.mixMethod = ""
        #expect(try inputs.validated().floor == nil)
    }

    @Test func switchingToSameForAllKeepsUnfinishedAdjustmentsWithoutApplyingThem() throws {
        var input = PricingProfileInputs(PricingProfile(id: "synthetic", name: "Synthetic", guideTerritory: "USA", rounding: "nearest", method: "ppp", percentages: ["SWE": 90]))
        input.overrides.append(.init(territory: "", percentage: "unfinished"))
        input.floor = "unfinished"; input.ceiling = "unfinished"
        let rows = input.overrides
        input.choose(method: "same")
        let saved = try input.validated()
        #expect(saved.percentages.isEmpty && saved.floor == nil && saved.ceiling == nil)
        #expect(input.overrides == rows && input.floor == "unfinished" && input.ceiling == "unfinished")
        input.choose(method: "ppp")
        #expect(throws: PricingFailure.self) { try input.validated() }
        input.overrides.removeLast(); input.floor = "80"; input.ceiling = "120"
        #expect(try input.validated().percentages == ["SWE": 90])
    }

    @Test func csvFilesFillPricesPercentagesAndYourOwnIndex() throws {
        let territories = [Territory(code: "USA", name: "United States", currency: "USD"), Territory(code: "SWE", name: "Sweden", currency: "SEK")]
        // The columns of Storebench's own price export are read as they are.
        let export = Data("app_id,territory,currency,amount,start_date,end_date\r\n1000000001,USA,USD,4.99,,\r\n1000000001,SWE,SEK,59.00,,\r\n".utf8)
        #expect(try PricingCSV.read(export, kind: .prices, territories: territories) == ["USA": "4.99", "SWE": "59.00"])
        #expect(try PricingCSV.read(Data("territory,amount\nswe,49\n".utf8), kind: .prices, territories: territories) == ["SWE": "49"])
        for invalid in ["territory,currency,amount\nSWE,EUR,49\n", "territory,amount\nSWE,49\nSWE,59\n", "territory,amount\nSE,49\n", "territory,amount\nSWE,0\n",
                        "territory,amount\nSWE,4,99\n", "app_id,territory,currency,amount,start_date,end_date\n1,SWE,SEK,49,2026-04-01,2026-04-30\n", "territory,price\nSWE,49\n"] {
            #expect(throws: PricingFailure.self) { try PricingCSV.read(Data(invalid.utf8), kind: .prices, territories: territories) }
        }
        #expect(try PricingCSV.read(Data("territory,percentage\nSWE,85\n".utf8), kind: .percentages, territories: []) == ["SWE": "85"])
        #expect(throws: PricingFailure.self) { try PricingCSV.read(Data("territory,percentage\nSWE,1001\n".utf8), kind: .percentages, territories: []) }
        #expect(throws: PricingFailure.self) { try PricingCSV.read(Data("territory,value\nXYZ,1\n".utf8), kind: .index, territories: []) }
        // Every copied format reads back.
        for kind in PricingCSV.Kind.allCases {
            let values = try PricingCSV.read(Data(kind.format.utf8), kind: kind, territories: [])
            #expect(values.count == 3)
        }
    }
}
