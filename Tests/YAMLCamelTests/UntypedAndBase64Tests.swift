import XCTest
@testable import YAMLCamel

final class UntypedLoadTests: XCTestCase {

    func testLoadMapping() throws {
        let root = try YAML.load(yaml: "a: 1\nb: hello\nc: true\n") as? [String: Any]
        XCTAssertEqual(root?["a"] as? Int, 1)
        XCTAssertEqual(root?["b"] as? String, "hello")
        XCTAssertEqual(root?["c"] as? Bool, true)
    }

    func testLoadNestedArraysAndMaps() throws {
        let y = """
        entries:
        - id: a
          title: First
        - id: b
          title: Second
        """
        let root = try YAML.load(yaml: y) as? [String: Any]
        let entries = root?["entries"] as? [[String: Any]]
        XCTAssertEqual(entries?.count, 2)
        XCTAssertEqual(entries?[1]["title"] as? String, "Second")
    }

    func testLoadEmptyReturnsNil() throws {
        XCTAssertNil(try YAML.load(yaml: ""))
        XCTAssertNil(try YAML.load(yaml: "null"))
    }

    func testDoubleDescriptionMatchesYamsExpectation() throws {
        // A Double has to coerce to the string "2.4" through `.description`.
        let root = try YAML.load(yaml: "minAppVersion: 2.4\n") as? [String: Any]
        let value = root?["minAppVersion"] as? Double
        XCTAssertEqual(value?.description, "2.4")
    }

    func testOnStaysStringNotBool() throws {
        let root = try YAML.load(yaml: "feature: on\n") as? [String: Any]
        XCTAssertEqual(root?["feature"] as? String, "on")
    }

    func testListIsNotAMapping() throws {
        XCTAssertNil(try YAML.load(yaml: "- a\n- b\n") as? [String: Any])
    }
}

final class UntypedDumpTests: XCTestCase {

    func testDumpRoundTripStringMap() throws {
        let dict = ["minAppVersion": "2.4.1", "feature": "on"]
        let yaml = try YAML.dump(object: dict, sortKeys: true)
        let back = try YAML.load(yaml: yaml) as? [String: Any]
        XCTAssertEqual(back?["minAppVersion"] as? String, "2.4.1")
        XCTAssertEqual(back?["feature"] as? String, "on")
    }

    func testDumpRoundTripsLargeIntExactly() throws {
        // A Double only carries 53 bits, so anything that boxed a big Int through NSNumber and
        // then judged it by magnitude alone used to round it: 10000000000000001 came back as the
        // unrelated number 10000000000000000.
        let original = 10_000_000_000_000_001 // > 2^53, well within Int64
        let yaml = try YAML.dump(object: ["id": original])
        let back = try YAML.load(yaml: yaml) as? [String: Any]
        XCTAssertEqual(back?["id"] as? Int, original)
    }

    func testDumpSortKeysDeterministic() throws {
        let dict = ["b": "2", "a": "1", "c": "3"]
        XCTAssertEqual(try YAML.dump(object: dict, sortKeys: true), try YAML.dump(object: dict, sortKeys: true))
        // Keys appear in sorted order.
        let yaml = try YAML.dump(object: dict, sortKeys: true)
        XCTAssertTrue(yaml.range(of: "a:")!.lowerBound < yaml.range(of: "b:")!.lowerBound)
        XCTAssertTrue(yaml.range(of: "b:")!.lowerBound < yaml.range(of: "c:")!.lowerBound)
    }
}

final class Base64Tests: XCTestCase {

    func testBase64RoundTrip() throws {
        let dict = ["minAppVersion": "2.4.1"]
        let b64 = try YAML.dumpBase64(object: dict, sortKeys: true)
        let back = YAML.loadBase64(b64) as? [String: Any]
        XCTAssertEqual(back?["minAppVersion"] as? String, "2.4.1")
    }

    func testBase64OfPlainYAMLDecodes() throws {
        let raw = Data("minAppVersion: 2.4.1\n".utf8).base64EncodedString()
        let back = YAML.loadBase64(raw) as? [String: Any]
        XCTAssertEqual(back?["minAppVersion"] as? String, "2.4.1")
    }

    func testInvalidBase64ReturnsNil() {
        XCTAssertNil(YAML.loadBase64("not valid base64 !!!"))
    }
}
