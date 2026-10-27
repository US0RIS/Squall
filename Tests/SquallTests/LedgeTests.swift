import XCTest
@testable import Squall

final class LedgeTests: XCTestCase {
    func testRelaxingConservesSnowOnAFloor() {
        let ledge = Ledge(id: -1, isFloor: true, x: 0, y: 500, width: 300)
        ledge.addSnow(at: 50, 20)
        let before = ledge.totalSnow
        for _ in 0..<200 { ledge.relaxSnow() }
        XCTAssertEqual(ledge.totalSnow, before, accuracy: 0.001)
        XCTAssertLessThan(ledge.snow.max() ?? 0, 10.5)
    }

    func testWindowEndsSpillExactlyWhatTheyLose() {
        let ledge = Ledge(id: 2, isFloor: false, x: 0, y: 500, width: 60)
        for i in 0..<ledge.count { ledge.snow[i] = 30 }
        let before = ledge.totalSnow
        for _ in 0..<300 { ledge.relaxSnow() }
        XCTAssertEqual(ledge.totalSnow + ledge.spillLeft + ledge.spillRight, before, accuracy: 0.01)
        XCTAssertGreaterThan(ledge.spillLeft + ledge.spillRight, 0)
    }

    func testWaterLevelsOutAndDrainsOffTheEnds() {
        let ledge = Ledge(id: 3, isFloor: false, x: 0, y: 0, width: 30)
        ledge.addWater(at: 5, 3)
        for _ in 0..<500 { ledge.flowWater(k: 1) }
        XCTAssertEqual(ledge.totalWater + ledge.dripLeft + ledge.dripRight, 3, accuracy: 0.001)
        XCTAssertGreaterThan(ledge.dripLeft + ledge.dripRight, 0)
    }

    func testResizeKeepsSnowInPlaceAndReturnsTheRest() {
        let ledge = Ledge(id: 4, isFloor: false, x: 100, y: 0, width: 300)
        for i in 0..<ledge.count { ledge.snow[i] = 2 }
        let total = ledge.totalSnow
        let loose = ledge.reshape(x: 100, y: 0, width: 150)
        let fell = loose.reduce(Float(0)) { $0 + $1.snow }
        XCTAssertEqual(ledge.totalSnow + fell, total, accuracy: 0.01)
        XCTAssertEqual(ledge.totalSnow, total / 2, accuracy: 0.5)
        XCTAssertTrue(loose.allSatisfy { $0.x >= 250 })
    }

    func testTakeAllEmptiesTheLedge() {
        let ledge = Ledge(id: 5, isFloor: false, x: 0, y: 0, width: 90)
        ledge.addSnow(at: 10, 5)
        ledge.addWater(at: 20, 1)
        let loose = ledge.takeAll()
        XCTAssertTrue(ledge.isEmpty)
        XCTAssertEqual(loose.reduce(Float(0)) { $0 + $1.snow + $1.water }, 6, accuracy: 0.001)
    }

    func testMeltTurnsSnowIntoWater() {
        let ledge = Ledge(id: 6, isFloor: true, x: 0, y: 0, width: 30)
        ledge.snow[3] = 1
        ledge.melt(rate: 10, dt: 1)
        XCTAssertEqual(ledge.snow[3], 0)
        XCTAssertEqual(ledge.water[3], 0.7, accuracy: 0.0001)
    }
}
