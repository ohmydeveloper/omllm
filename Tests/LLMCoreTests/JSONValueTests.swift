import Foundation
import LLMCore
import Testing

@Suite("JSONValue")
struct JSONValueTests {
    @Test(
        "JSON values round trip",
        arguments: [
            JSONValue.null,
            .boolean(true),
            .number(42.5),
            .string("value"),
            .array([.number(1), .string("two")]),
            .object(["key": .boolean(false)]),
        ]
    )
    func roundTrip(value: JSONValue) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("nested values round trip and remain equal")
    func nestedRoundTrip() throws {
        let value = JSONValue.object([
            "name": .string("weather"),
            "required": .boolean(true),
            "limit": .number(3),
            "nullable": .null,
            "items": .array([
                .object(["city": .string("Kyiv")]),
                .number(2.5),
            ]),
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == value)
        #expect(decoded != .object([:]))
    }

    @Test("typed accessors return only matching values")
    func accessors() {
        let value = JSONValue.object([
            "array": .array([.null]),
            "boolean": .boolean(true),
            "number": .number(2),
            "string": .string("text"),
        ])

        #expect(value["array"]?.arrayValue == [.null])
        #expect(value["boolean"]?.boolValue == true)
        #expect(value["number"]?.numberValue == 2)
        #expect(value["string"]?.stringValue == "text")
        #expect(value["string"]?.numberValue == nil)
        #expect(value["missing"] == nil)
    }
}
