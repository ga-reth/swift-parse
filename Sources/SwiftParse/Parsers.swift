//
//  Parsers.swift
//  SwiftParse
//
//  Created by Matt Gadda on 11/30/19.
//

// MARK: Parser Types

/// A generic parser (a function) representing a parsing computation
/// which reads one or more values from some `SourceType` (which must be a `Collection`)
/// and produces a `ParsedValueType` and some remaining `OutputType`
public typealias Parser<InputElement, ParsedValue, OutputElement> =
    (AnyCollection<InputElement>) -> ParseResult<AnyCollection<InputElement>, ParsedValue, AnyCollection<OutputElement>>

/// When the type from which values are parsed is the same before and after parsing, and that type conforms to `Collection`
/// we call this a `StandardParser`.
public typealias StandardParser<T: Collection, U> = Parser<T.Element, U, T.Element>

public typealias ParserFrom<ParserLike: ParserConvertible> =
    Parser<ParserLike.InputType.Element, ParserLike.ParsedValueType, ParserLike.OutputType.Element>

public typealias HomogeneousParser<T: Collection> = StandardParser<T, T>

/// When parser fails, it returns a `ParseError` describing the reason
/// and location of the failure.
public struct ParseError<Element>: Error {
    public let at: AnyCollection<Element>
    public let reason: String?
    public init<C: Collection>(at: C, reason: String? = .none) where C.Element == Element {
        self.at = AnyCollection(at)
        self.reason = reason
    }
}

/// A protocol that can be used to make objects such as String or Array literals
/// behave implicitly as parsers that match themselves, when used in appropriate contexts.
/// Example:
/// ```
/// let parser = "(" ~ value ~ ")"
/// ```
/// The common types have extensions included with SwiftParse so that the
/// above Just Works™.
public protocol ParserConvertible {
    associatedtype InputType: Collection = Self
    associatedtype ParsedValueType = Self
    associatedtype OutputType: Collection = Self
    func mkParser() -> Parser<InputType.Element, ParsedValueType, OutputType.Element>
}

/// All parsers return a `ParseResult` to indicate success or failure.
public typealias ParseResult<InputType: Collection, ParsedValueType, OutputType> =
    Result<(value: ParsedValueType, out: OutputType), ParseError<InputType.Element>>

// MARK: match

/// A parser which matches the prefix `pattern`
public func match<InputType: Collection>(prefix: InputType) ->
    StandardParser<InputType, AnyCollection<InputType.Element>> where
    InputType.Element: Equatable
{
    return { source in
        if source.starts(with: prefix, by: { $0 == $1 }) {
            return .success((source.prefix(prefix.count), AnyCollection(source).dropFirst(prefix.count)))
        } else {
            return .failure(ParseError(at: source, reason: "expected \(prefix)"))
        }
    }
}

public func match<InputElement: Equatable>(element: InputElement) -> StandardParser<AnyCollection<InputElement>, InputElement> {
    return { source in
        // TODO: should match(prefix:) be rewritten to use match(element:)?
        // i.e. inverting the dependency? or would that just introduce inefficiencies
        // and perhaps both of these methods should have their own implementation
        match(prefix: [element])(source).flatMap { value, remainder in
            value
                .first
                .liftToResult(orFailWith: ParseError(at: source, reason: "expected \(element) but found nothing"))
                .map { ($0, remainder) }
        }
    }
}

func match<InputType: Collection>(range: ClosedRange<InputType.Element>) -> (InputType) -> Result<(InputType.Element, InputType.SubSequence), ParseError<InputType.Element>> {
    return { source in
        guard let first = source.first else {
            return .failure(ParseError(at: source, reason: "expected range \(range) but found nothing"))
        }

        if range.contains(first) {
            return .success((first, source.dropFirst()))
        } else {
            return .failure(ParseError(at: source, reason: "expected \(first) to be in range \(range)"))
        }
    }
}

/// Generates a parser that matches one of the characters contained within `oneOf`
public func match<InputElement: Equatable, SetLike: SetAlgebra>(oneOf pattern: SetLike) -> Parser<InputElement, InputElement, InputElement> where SetLike.Element == InputElement {
    return { source in
        // TODO: extract this into a method/Result for reuse
        guard let first = source.first else {
            return .failure(ParseError(at: source, reason: "unexpected something but found nothing"))
        }

        if pattern.contains(first) {
            return .success((first, source.dropFirst()))
        }

        return .failure(ParseError(at: source, reason: "expected one of \(pattern)"))
    }
}

public func match<T>(_ fn: @escaping (T) -> Bool) -> Parser<T, T, T> {
    return { source in
        guard let first = source.first else {
            return .failure(ParseError(at: source, reason: "expected something but found nothing"))
        }

        if fn(first) {
            return .success((first, source.dropFirst()))
        } else {
            // TODO: make this error message useful
            return .failure(ParseError(at: AnyCollection(source), reason: "match failed because \(String(describing: fn)) returned false"))
        }
    }
}

// TODO: should `matchIf` really require source to be present
// at the time in which the parser is generated?
// And if not, then matchIf could be rewritten using `match(fn:)` above.
public func matchOneIf<InputElement>(_ source: AnyCollection<InputElement>, fn: @escaping (InputElement) -> Bool) -> ParseResult<AnyCollection<InputElement>, InputElement, AnyCollection<InputElement>> {
    guard let first = source.first else {
        return .failure(ParseError(at: source))
    }

    if fn(first) {
        return .success((first, source.dropFirst()))
    } else {
        // matchOneIf is a building block so caller
        // is expected to provide a meaningful failure reason
        return .failure(ParseError(at: source))
    }
}

// MARK: reject

public func reject<InputElement>(element: InputElement) -> Parser<InputElement, InputElement, InputElement> where InputElement: Equatable {
    return { source in
        matchOneIf(source) { $0 != element }.mapError {
            if let _ = $0.reason {
                return $0
            } else {
                return ParseError(at: $0.at, reason: "expected next token to not equal \(element)")
            }
        }
    }
}

/// Generates a `Parser` that succeeds if the first element in the `Collection`
/// being parsed is not any of the characters found in `anyOf`.
public func reject<T: Collection>(anyOf pattern: T) -> StandardParser<T, T.Element>
    where T.Element: Equatable
{
    return { source in
        for ch in pattern {
            if case .success = matchOneIf(source, fn: { $0 == ch }) {
                return .failure(ParseError(at: AnyCollection(source), reason: "did not expect \(ch)"))
            }
        }
        if let first = source.first {
            return .success((first, source.dropFirst()))
        } else {
            return .failure(ParseError(at: AnyCollection(source), reason: "unexpectedly at end of input"))
        }
    }
}

// MARK: lookAhead

/// Generates a parser that succeeds when `parser` succeeds but
/// consumes no tokens from the input. This method could have
/// been called `guard` if that weren't a keyword.
public func lookAhead<T, InputElement>(
    _ parser: @autoclosure @escaping () -> Parser<InputElement, T, InputElement>
) -> Parser<InputElement, T, InputElement> {
    return { source in
        parser()(source).map { value, _ in
            (value, source)
        }
    }
}

public func lookAhead<ParserLike: ParserConvertible>(
    _ parser: ParserLike
) -> ParserFrom<ParserLike> where ParserLike.InputType == ParserLike.OutputType {
    lookAhead(parser.mkParser())
}

// MARK: not

/// Generates a parser that succeeds with a void value and consumes
/// no tokens from the input when `parser` fails; fails when
/// `parser` succeeds and consumes no tokens from the input.
public func not<ParsedValue, InputElement>(
    _ parser: @autoclosure @escaping () -> Parser<InputElement, ParsedValue, InputElement>
) -> Parser<InputElement, Void, InputElement> {
    return { source in
        switch parser()(source) {
        case let .success((value, _)):
            return .failure(ParseError(at: source, reason: "Expected failure but found \(value)"))
        case .failure:
            return .success(((), source))
        }
    }
}

public func not<ParserLike: ParserConvertible>(
    _ parser: ParserLike
) -> Parser<ParserLike.InputType.Element, Void, ParserLike.OutputType.Element> where
    ParserLike.InputType == ParserLike.OutputType
{
    return { source in
        not(parser.mkParser())(source)
    }
}

// MARK: compose

/// A parser that succeeds when `left` and `right` both succeed in order.
/// The output of the first is passed to the input of the second.
func compose<T, U, V, LeftParsedValue, RightParsedValue>(
    _ left: @autoclosure @escaping () -> Parser<T, LeftParsedValue, U>,
    _ right: @autoclosure @escaping () -> Parser<U, RightParsedValue, V>
) -> Parser<T, (LeftParsedValue, RightParsedValue), V> {
    return { source in
        left()(source).flatMap { leftResult in
            right()(leftResult.1).map { rightResult in
                ((leftResult.0, rightResult.0), rightResult.1)
            }.mapError {
                ParseError(at: source, reason: $0.reason)
            }
        }
    }
}

func compose<ParserTU: ParserConvertible, ParserUV: ParserConvertible>(
    _ left: ParserTU,
    _ right: ParserUV
) -> Parser<
    ParserTU.InputType.Element,
    (ParserTU.ParsedValueType, ParserUV.ParsedValueType),
    ParserUV.OutputType.Element
> where
    ParserTU.OutputType == ParserUV.InputType
{
    return compose(left.mkParser(), right.mkParser())
}

func compose<T, U, LeftParsedValue, ParserUV: ParserConvertible>(
    _ left: @autoclosure @escaping () -> Parser<T, LeftParsedValue, U>,
    _ right: ParserUV
) -> Parser<T, (LeftParsedValue, ParserUV.ParsedValueType), ParserUV.OutputType.Element> where
    U == ParserUV.InputType.Element
{
    return compose(left(), right.mkParser())
}

func compose<ParserTU: ParserConvertible, U, V, RightParsedValue>(
    _ left: ParserTU,
    _ right: @autoclosure @escaping () -> Parser<U, RightParsedValue, V>
) -> Parser<ParserTU.InputType.Element, (ParserTU.ParsedValueType, RightParsedValue), V> where
    ParserTU.OutputType.Element == U
{
    return compose(left.mkParser(), right())
}

// MARK: rep

/// Generates a parser that suceeds if `parser` succeeds zero or more times.
/// This parser never fails.
public func rep<InputElement, ParsedValue>(_ parser: @autoclosure @escaping () -> Parser<InputElement, ParsedValue, InputElement>) -> Parser<InputElement, [ParsedValue], InputElement> {
    return { source in
        // TODO: determine if tail call optimization happens here
        // manually optimize if not.
        func aggregate(remaining: AnyCollection<InputElement>, parsedValues: [ParsedValue]) -> ([ParsedValue], AnyCollection<InputElement>) {
            if case let .success(result) = parser()(remaining) {
                return aggregate(
                    remaining: result.1,
                    parsedValues: parsedValues + [result.0]
                )
            }
            return (parsedValues, remaining)
        }

        return .success(aggregate(remaining: source, parsedValues: []))
    }
}

public func rep<ParserLike: ParserConvertible>(
    _ parser: ParserLike
) -> StandardParser<ParserLike.InputType, [ParserLike.ParsedValueType]>
    where ParserLike.InputType == ParserLike.OutputType
{
    return rep(parser.mkParser())
}

// MARK: rep1

/// Generators a parser that succeeds if `parser` succeeds at least once and fails if `parser` fails.
public func rep1<InputElement, ParsedValue>(_ parser: @autoclosure @escaping () -> Parser<InputElement, ParsedValue, InputElement>) -> Parser<InputElement, [ParsedValue], InputElement> {
    let repParser = rep(parser())
    return map(compose(parser(), repParser)) { first, rest in
        [first] + rest
    }
}

public func rep1<ParserLike: ParserConvertible>(
    _ parser: ParserLike
) -> StandardParser<ParserLike.InputType, [ParserLike.ParsedValueType]>
    where ParserLike.InputType == ParserLike.OutputType
{
    rep1(parser.mkParser())
}

// MARK: either

/// Generates a heterogeneous parser that succeeds if either `left` or `right` succeeds. `left` is
/// executed first and then right if `left` fails. This parser fails if both `left` and `right` fail.
/// The parsed output of `left` and `right` must be different types.
public func either<T, U, InputElement, OutputElement>(
    _ left: @autoclosure @escaping () -> Parser<InputElement, T, OutputElement>,
    _ right: @autoclosure @escaping () -> Parser<InputElement, U, OutputElement>
) -> Parser<InputElement, Either<T, U>, OutputElement> {
    return { source in
        if case let .success((value, remainder)) = left()(source) {
            return .success((.left(value), remainder))
        } else if case let .success((value, remainder)) = right()(source) {
            return .success((.right(value), remainder))
        } else {
            return .failure(ParseError(at: source))
        }
    }
}

// MARK: or

/// Generates a homogenous parser that succeeds if either `left` or `right` succeeds. `left` is
/// executed first and then right if `left` fails. This parser fails if both `left` and `right` fail.
/// The parsed output of `left` and `right` must be the same  type `T`.
public func or<T, U, ParsedValue>(
    _ left: @autoclosure @escaping () -> Parser<T, ParsedValue, U>,
    _ right: @autoclosure @escaping () -> Parser<T, ParsedValue, U>
) -> Parser<T, ParsedValue, U> {
    return { source in
        var underlyingErrors: [String] = []

        let leftResult = left()(source)
        switch leftResult {
        case .success: return leftResult
        case let .failure(e):
            if let reason = e.reason {
                underlyingErrors.append(reason)
            }
        }

        let rightResult = right()(source)
        switch rightResult {
        case .success: return rightResult
        case let .failure(e):
            if let reason = e.reason {
                underlyingErrors.append(reason)
            }
        }

        return .failure(ParseError(
            at: source,
            reason: underlyingErrors.joined(separator: " or ")
        )
        )
    }
}

public func or<ParserLike: ParserConvertible>(
    _ left: @autoclosure @escaping () -> ParserFrom<ParserLike>,
    _ right: ParserLike
) -> ParserFrom<ParserLike> {
    or(left(), right.mkParser())
}

public func or<ParserLike: ParserConvertible>(
    _ left: ParserLike,
    _ right: @autoclosure @escaping () -> ParserFrom<ParserLike>
) -> ParserFrom<ParserLike> {
    or(left.mkParser(), right())
}

public func or<ParserLike: ParserConvertible>(
    _ left: ParserLike,
    _ right: ParserLike
) -> ParserFrom<ParserLike> {
    or(left.mkParser(), right.mkParser())
}

// MARK: opt

/// Generates a parser that always succeeds regardless of whether the underlying parser succeeds.
/// If `parser` succeeds, its value is returned as the parsed result. If `parser` fails, None is returned
/// as the parsed result.
public func opt<InputElement, ParsedValue>(
    _ parser: @autoclosure @escaping () -> Parser<InputElement, ParsedValue, InputElement>
) -> Parser<InputElement, ParsedValue?, InputElement> {
    return { source in
        switch parser()(source) {
        case let .success(s): return .success(s)
        case .failure: return .success((nil, source))
        }
    }
}

public func opt<ParserLike: ParserConvertible>(
    _ parser: ParserLike
) -> StandardParser<ParserLike.InputType, ParserLike.ParsedValueType?>
    where ParserLike.InputType == ParserLike.OutputType
{
    opt(parser.mkParser())
}

/// Generates a parser which always succeeds with the next element in the input
/// unless there is no next element.
public func always<InputElement>(source: AnyCollection<InputElement>) -> ParseResult<AnyCollection<InputElement>, InputElement, AnyCollection<InputElement>> {
    guard let first = source.first else {
        return .failure(ParseError(at: source, reason: "Expected something but found nothing"))
    }
    return .success((value: first, out: source.dropFirst()))
}

// MARK: and

/// Generates a parse which succeeds with the parsed value from `left` when
/// `left` and `right` both succeed.
///
/// Unlike `compose`, the remainder after executing `left` is not then passed
/// to `right`. They are not composed: both parsers operate in parallel starting
/// at the same place in the input stream.
///
/// This parser can be useful when you want to subtract possible elements away from
/// an allowable set defined by `left`, especially when the thing being subtracted
/// away from `left` is a complex parser itself.
///
/// The output of `right` is assumed to be unneeded.
///
/// Example:
/// ```
/// let parser = and(match(CharacterSet.alphanumeric), not(match(element: Character("a"))))
/// parser(AnyCollection("b")) // => Result.success(...)
/// parser(AnyCollection("a")) // => Result.failure(...)
/// ```
public func and<T, U, V, LeftValue, RightValue>(
    _ left: @autoclosure @escaping () -> Parser<T, LeftValue, U>,
    _ right: @autoclosure @escaping () -> Parser<T, RightValue, V>
) -> Parser<T, LeftValue, U> {
    return { source in
        switch (left()(source), right()(source)) {
        case let (.success((value, out)), .success):
            return .success((value, out))
        case let (.failure(error), _):
            return .failure(ParseError(at: error.at, reason: error.reason))
        case let (_, .failure(error)):
            return .failure(ParseError(at: error.at, reason: error.reason))
        }
    }
}

// TODO: should `and` return a tuple to allow the use of the right's output?
public func and<V, RightValue, ParserTU: ParserConvertible>(
    _ left: ParserTU,
    _ right: @autoclosure @escaping () -> Parser<ParserTU.InputType.Element, RightValue, V>
) -> ParserFrom<ParserTU> {
    and(left.mkParser(), right())
}

public func and<U, LeftValue, ParserTV: ParserConvertible>(
    _ left: @autoclosure @escaping () -> Parser<ParserTV.InputType.Element, LeftValue, U>,
    _ right: ParserTV
) -> Parser<ParserTV.InputType.Element, LeftValue, U> {
    and(left(), right.mkParser())
}

public func and<ParserTU: ParserConvertible, ParserTV: ParserConvertible>(
    _ left: ParserTU,
    _ right: ParserTV
) -> ParserFrom<ParserTU>
    where ParserTU.InputType == ParserTV.InputType
{
    and(left.mkParser(), right.mkParser())
}

/// A stand-in parser that fails for all input. It should be used to construct mutually recursive parser definitions
public func placeholder<T, InputElement>(_ source: AnyCollection<InputElement>) -> ParseResult<AnyCollection<InputElement>, T, AnyCollection<InputElement>> {
    return .failure(ParseError(at: source, reason: "Not yet implemented"))
}

/// A parser that matches only if `source` is empty.
public func eof<InputType: Collection>(_ source: InputType) -> ParseResult<InputType, Nothing, InputType> {
    if source.isEmpty {
        return .success((nil, source))
    } else {
        return .failure(ParseError(at: AnyCollection(source), reason: "Expected eof but found something"))
    }
}
