import XCTest
@testable import SwiftParse

protocol ParserHelpers {
  func assertParsed<T: Equatable, U: Equatable>(
    _ parser: Parser<T, U>,
    input: T,
    val: U,
    remaining: T,
    message: @autoclosure () -> String,
    file: StaticString,
    line: UInt
  )
}

extension ParserHelpers {
  func assertParsed<T: Equatable, U: Equatable>(
        _ parser: Parser<T, U>,
    input: T,
    val: U,
    remaining: T,
    message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
  ) {
    switch parser(input) {
    case let .success(s):
        XCTAssertEqual(s.0, val, message(), file: file, line: line)
        XCTAssertEqual(s.1, remaining, message(), file: file, line: line)
    case let .failure(e): XCTFail("Failed to parse at \(e.at)", file: file, line: line)
    }    
  }

  func assertNotParsed<T: Equatable, U: Equatable>(
    _ parser: Parser<T, U>,
    input: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
  ) {
    switch parser(input) {
    case .success: XCTFail(message(), file: file, line: line)
    case .failure: return
    }
  }
}
