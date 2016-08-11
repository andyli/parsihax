package parsihax;

typedef Index = {
  var offset: Int;
  @:optional var line: Int;
  @:optional var column: Int;
}

typedef Data = {
  @:optional var status : Bool;
  @:optional var index : Int;
  @:optional var value: Dynamic;
  @:optional var furthest: Int;
  @:optional var expected : Array<String>;
};

enum Result {
  Success(value : Dynamic);
  Failure(index : Index, expected : Array<String>);
}

/**
 * An atomic mutable reference to {@link Parser} used in recursive grammars.
 */
class Ref extends Parser {
  private function new(action : String -> Int -> Data) {
    super(action);
  }

  public function set(parser : Parser) : Ref {
    this.action = parser.action;
    return this;
  }
}

/**
 * Defines grammar and encapsulates parsing logic. A {@link Parser} takes as input a
 * {@link String} source and parses it when the {@link #parse(String)} method is called.
 * An enum {@link Result} is return, which can be Success(value : Dynamic) or
 * Failure(index : Index, expected : Array<String>)
 */
class Parser {
  /**
   * Equivalent to regexp [a-z] /i
   */
  public static function letter() : Parser {
    return regexp(~/[a-z]/i).desc('a letter');
  }

  /**
   * Equivalent to regexp [a-z]* /i
   */
  public static function letters() : Parser {
    return regexp(~/[a-z]*/i);
  }

  /**
   * Equivalent to regex [0-9]
   */
  public static function digit() : Parser {
    return regexp(~/[0-9]/).desc('a digit');
  }

  /**
   * Equivalent to regexp [0-9]*
   */
  public static function digits() : Parser {
    return regexp(~/[0-9]*/);
  }

  /**
   * Equivalent to regexp \s+
   */
  public static function whitespace() : Parser {
    return regexp(~/\s+/).desc('whitespace');
  }

  /**
   * Equivalent to regexp \s*
   */
  public static function optWhitespace() : Parser {
    return regexp(~/\s*/);
  }

  /**
   * A parser that consumes and yields the next character of the stream.
   */
  public static function any() : Parser {
    return new Parser(function(stream, i) {
      return i >= stream.length
        ? makeFailure(i, 'any character')
        : makeSuccess(i+1, stream.charAt(i));
    });
  }

  /**
   * A parser that consumes and yields the entire remainder of the stream.
   */
  public static function all() : Parser {
    return new Parser(function(stream, i) {
      return makeSuccess(stream.length, stream.substring(i));
    });
  }

  /**
   * A parser that expects to be at the end of the stream (zero characters left).
   */
  public static function eof() : Parser {
    return new Parser(function(stream, i) {
      return i < stream.length
        ? makeFailure(i, 'EOF')
        : makeSuccess(i, null);
    });
  }

  /**
   * A parser that consumes no text and yields an object an object representing the current offset into the parse:
   * it has a 0-based character offset property and 1-based line and column properties.
   */
  public static function index() : Parser {
    return new Parser(function(stream, i) {
      return makeSuccess(i, makeLineColumnIndex(stream, i));
    });
  }

  /**
   * Create parser reference, usefull for recursive parsers. If parsing is tried on this reference
   * directly, without concating it, it returns failed parser.
   */
  public static function ref() : Ref {
    return new Ref(fail('actual parser, and not reference').action);
  }

  /**
   * Returns a parser that looks for string and yields that exact value.
   */
  public static function string(str : String) : Parser {
    var len = str.length;
    var expected = "'"+str+"'";

    return new Parser(function(stream, i) {
      var head = stream.substring(i, i + len);

      if (head == str) {
        return makeSuccess(i+len, head);
      } else {
        return makeFailure(i, expected);
      }
    });
  }

  /**
   * Returns a parser that looks for exactly one character from string, and yields that character.
   */
  public static function oneOf(str : String) : Parser {
    return test(function(ch) {
      return str.indexOf(ch) >= 0;
    });
  }

  /**
   * Returns a parser that looks for exactly one character NOT from string, and yields that character.
   */
  public static function noneOf(str : String) : Parser {
    return test(function(ch) {
      return str.indexOf(ch) < 0;
    });
  }

  /**
   * Returns a parser that looks for a match to the regexp and yields the given match group (defaulting to the entire match).
   * The regexp will always match starting at the current parse location. The regexp may only use the following flags: imu.
   * Any other flag will result in an error being thrown.
   */
  public static function regexp(re : EReg, group : Int = 0) : Parser {
    var expected = Std.string(re);
    
    return new Parser(function(stream, i) {
      var match = re.match(stream.substring(i));

      if (match) {
        var groupMatch = re.matched(group);
        var pos = re.matchedPos();
        if (groupMatch != null && pos.pos == 0) {
          return makeSuccess(i + pos.len, groupMatch);
        }
      }

      return makeFailure(i, expected);
    });
  }

  /**
   * This is an alias for Parser.regexp
   */
  public static function regex(re : EReg, group : Int = 0) : Parser {
    return regexp(re, group);
  }

  /**
   * Returns a parser that doesn't consume any of the string, and yields result. 
   */
  public static function succeed(value : Dynamic) : Parser {
    return new Parser(function(stream, i) {
      return makeSuccess(i, value);
    });
  }

  /**
   * This is an alias for Parser.succeed(result). 
   */
  public static function of(value : Dynamic) : Parser {
    return succeed(value);
  }

  /**
   * Accepts any number of parsers and returns a new parser that expects them to match in order, yielding an array of all their results.
   */
  public static function seq(parsers : Array<Parser>) : Parser {
    var numParsers = parsers.length;

    return new Parser(function(stream, i) {
      var result = null;
      var accum : Array<Dynamic> = [];

      for (parser in parsers) {
        result = mergeReplies(parser.action(stream, i), result);
        if (!result.status) return result;
        accum.push(result.value);
        i = result.index;
      }

      return mergeReplies(makeSuccess(i, accum), result);
    });
  }

  /**
   * Matches all parsers sequentially, and passes their results as the arguments to a function. Similar as calling Parser.seq
   * and then .map.
   */
  public static function seqMap(parsers : Array<Parser>, mapper : Array<Dynamic> -> Dynamic) : Parser {
    return seq(parsers).map(function(results) {
      return mapper(results);
    });
  }

  /**
   * Accepts any number of parsers, yielding the value of the first one that succeeds, backtracking in between.
   * This means that the order of parsers matters. If two parsers match the same prefix, the longer of the two must come first. 
   */
  public static function alt(parsers : Array<Parser>) : Parser {
    var numParsers = parsers.length;
    if (numParsers == 0) return fail('zero alternates');

    return new Parser(function(stream, i) {
      var result = null;

      for (parser in parsers) {
        result = mergeReplies(parser.action(stream, i), result);
        if (result.status) return result;
      }

      return result;
    });
  }

  /**
   * Accepts two parsers, and expects zero or more matches for content, separated by separator, yielding an array.
   */
  public static function sepBy(parser : Parser, separator : Parser) : Parser {
    return sepBy1(parser, separator).or(of([]));
  }

  /**
   * This is the same as Parser.sepBy, but matches the content parser at least once.
   */
  public static function sepBy1(parser : Parser, separator : Parser) : Parser {
    var pairs = separator.then(parser).many();

    return parser.chain(function(r) {
      return pairs.map(function(rs) {
        return [r].concat(rs);
      });
    });
  }

  /**
   * Accepts a function that returns a parser, which is evaluated the first time the parser is used.
   * This is useful for referencing parsers that haven't yet been defined, and for implementing recursive parsers.
   */
  public static function lazy(f : Void -> Parser, ?desc : String) : Parser {
    var parser : Parser = null;
    
    parser = new Parser(function(stream, i) {
      parser.action = f().action;
      return parser.action(stream, i);
    });

    if (desc != null) parser = parser.desc(desc);
    return parser;
  }

  /**
   * Returns a failing parser with the given message.
   */
  public static function fail(expected : String) : Parser {
    return new Parser(function(stream, i) {
      return makeFailure(i, expected);
    });
  }

  /**
   * Returns a parser that yield a single character if it passes the predicate function.
   */
  public static function test(predicate : String -> Bool) : Parser {
    return new Parser(function(stream, i) {
      var char = stream.charAt(i);

      return i < stream.length && predicate(char)
        ? makeSuccess(i+1, char)
        : makeFailure(i, 'a character matching '+predicate);
    });
  }

  /**
   * Returns a parser yield a string containing all the next characters that pass the predicate.
   */
  public static function takeWhile(predicate : String -> Bool) : Parser {
    return new Parser(function(stream, i) {
      var j = i;
      while (j < stream.length && predicate(stream.charAt(j))) j += 1;
      return makeSuccess(j, stream.substring(i, j));
    });
  }

  /**
   * You can add a primitive parser (similar to the included ones) by using Parser.custom.
   */
  public static function custom(parsingFunction) : Parser {
    return new Parser(parsingFunction(makeSuccess, makeFailure));
  }

  /**
   * Obtain a human-readable error string.
   */
  public static function formatError(stream : String, index : Index, expected : Array<String>) : String {
    var sexpected = expected.length == 1
      ? expected[0]
      : 'one of ' + expected.join(', ');
    
    var got = '';
    var i = index.offset;

    if (i == stream.length) {
      got = ', got the end of the stream';
    } else {
      var prefix = (i > 0 ? "'..." : "'");
      var suffix = (stream.length - i > 12 ? "...'" : "'");

      got = ' at line ' + index.line + ' column ' + index.column
        +  ', got ' + prefix + stream.substring(i, i + 12) + suffix;
    }

    return 'expected ' + sexpected + got;
  }

  /**
   * Calling .parse(string) on a parser parses the string and returns an object with a boolean status flag,
   * indicating whether the parse succeeded. If it succeeded, the value attribute will contain the yielded value.
   * Otherwise, the index and expected attributes will contain the index of the parse error
   * (with offset, line and column properties), and a sorted, unique array of messages indicating what was expected.
   */
  public function parse(stream : String) : Result {
    var result = this.skip(eof()).action(stream, 0);

    return result.status
      ? Success(result.value)
      : Failure(makeLineColumnIndex(stream, result.furthest), result.expected);
  }

  /**
   * Returns a new parser which tries parser, and if it fails uses otherParser.
   */
  public function or(alternative : Parser) : Parser {
    return alt([this, alternative]);
  }

  /**
   * Returns a new parser which tries parser, and on success calls the function newParserFunc with the result
   * of the parse, which is expected to return another parser, which will be tried next. This allows you to
   * dynamically decide how to continue the parse, which is impossible with the other combinators.
   */
  public function chain(f : Dynamic -> Parser) : Parser {
    return new Parser(function(stream, i) {
      var result = this.action(stream, i);
      if (!result.status) return result;
      var nextParser = f(result.value);
      return mergeReplies(nextParser.action(stream, result.index), result);
    });
  }

  /**
   * Expects anotherParser to follow parser, and yields the result of anotherParser.
   */
  public function then(next : Parser) : Parser {
    return seq([this, next]).map(function(results) {
      return results[1];
    });
  }

  /**
   * Transforms the output of parser with the given function.
   */
  public function map(fn : Dynamic -> Dynamic) : Parser {
    return new Parser(function(stream, i) {
      var result = this.action(stream, i);
      if (!result.status) return result;
      return mergeReplies(makeSuccess(result.index, fn(result.value)), result);
    });
  }

  /**
   * Returns a new parser with the same behavior, but which yields value. Equivalent to parser.map(function(x) { return x; }.bind(value)).
   */
  public function result(res : Dynamic) : Parser {
    return this.map(function(_) { return res; });
  }

  /**
   * Expects otherParser after parser, but yields the value of parser.
   */
  public function skip(next : Parser) : Parser {
    return seq([this, next]).map(function(results) {
      return results[0];
    });
  };

  /**
   * Expects parser zero or more times, and yields an array of the results.
   */
  public function many() : Parser {
    return new Parser(function(stream, i) {
      var accum = [];
      var result = null;
      var prevResult = null;

      while (true) {
        result = mergeReplies(this.action(stream, i), result);

        if (result.status) {
          i = result.index;
          accum.push(result.value);
        } else {
          return mergeReplies(makeSuccess(i, accum), result);
        }
      }
    });
  }

  /**
   * Expects parser between min and max times (or exactly x times, when second argument is omitted),
   * and yields an array of the results.
   */
  public function times(min : Int, ?max : Int) : Parser {
    if (max == null) max = min;

    return new Parser(function(stream, i) {
      var accum = [];
      var start = i;
      var result = null;
      var prevResult = null;

      for (times in 0...min) {
        result = this.action(stream, i);
        prevResult = mergeReplies(result, prevResult);
        if (result.status) {
          i = result.index;
          accum.push(result.value);
        } else return prevResult;
      }

      for (times in 0...max) {
        result = this.action(stream, i);
        prevResult = mergeReplies(result, prevResult);
        if (result.status) {
          i = result.index;
          accum.push(result.value);
        }
        else break;
      }

      return mergeReplies(makeSuccess(i, accum), prevResult);
    });
  }

  /**
   * Expects parser at most n times. Yields an array of the results.
   */
  public function atMost(n : Int) : Parser {
    return times(0, n);
  }

  /**
   * Expects parser at least n times. Yields an array of the results.
   */
  public function atLeast(n : Int) : Parser {
    return seqMap([times(n), many()], function(results) {
      return results[0].concat(results[1]);
    });
  }

  /**
   * Yields an object with start, value, and end keys, where value is the original value yielded by the parser,
   * and start and end are are objects with a 0-based offset and 1-based line and column properties that represent
   * the position in the stream that contained the parsed text.
   */
  public function mark() : Parser {
    return seqMap([index(), this, index()], function(results) {
      return { start: results[0], value: results[1], end: results[2] };
    });
  }

  /**
   * Returns a new parser whose failure message is description. For example, string('x').desc('the letter x')
   * will indicate that 'the letter x' was expected.
   */
  public function desc(expected : String) : Parser {
    return new Parser(function(stream, i) {
      var reply = this.action(stream, i);
      if (!reply.status) reply.expected = [expected];
      return reply;
    });
  }

  /**
   * This is an alias for parser.or(other)
   */
  public function concat(other : Parser) : Parser {
    return or(other);
  }

  /**
   * Returns a new failed parser with 'empty' message
   */
  public function empty() : Parser {
    return fail('empty');
  }

  /**
   * Applies other parser to new parser
   */
  public function ap(other : Parser) : Parser {
    return seqMap([this, other], function(results) { return results[0](results[1]); });
  }

  /**
   * Returns a new parser which tries parser, and if it fails returns null (like PEG optional case)
   */
  public function maybe() : Parser {
    return or(of(null));
  }

  /**
   * Returns a new parser that assigns value if result value is null (from maybe())
   */
  public function els(defaulting : Void -> Parser) : Parser {
    return new Parser(function(stream, i) {
      var result = this.action(stream, i);

      if (result.status && result.value == null) {
        result.value = defaulting();
      }
      
      return result;
    });
  }

  // Parser function
  private var action : String -> Int -> Data;

  /**
   * The Parser object is a wrapper for a parser function.
   * Externally, you use one to parse a string by calling
   *   var result = SomeParser.parse('Me Me Me! Parse Me!');
   * You should never need to call the constructor, rather you should
   * construct your Parser from the base parsers and the
   * parser combinator methods.
   */
  private function new(action : String -> Int -> Data) {
    this.action = action;
  }

  private static function makeSuccess(index : Int, value : Dynamic) : Data {
    return {
      status: true,
      index: index,
      value: value,
      furthest: -1,
      expected: []
    };
  }

  private static function makeFailure(index : Int, expected : String) : Data {
    return {
      status: false,
      index: -1,
      value: null,
      furthest: index,
      expected: [expected]
    };
  }

  private static function makeLineColumnIndex(stream : String, i : Int) : Index {
    var lines = stream.substring(0, i).split("\n");
    var lineWeAreUpTo = lines.length;
    var columnWeAreUpTo = lines[lines.length - 1].length + 1;

    return {
      offset: i,
      line: lineWeAreUpTo,
      column: columnWeAreUpTo
    };
  };

  private static function mergeReplies(result : Data, ?last : Data) : Data {
    if (last == null) return result;
    if (result.furthest > last.furthest) return result;

    var expected = (result.furthest == last.furthest)
      ? unsafeUnion(result.expected, last.expected)
      : last.expected;

    return {
      status: result.status,
      index: result.index,
      value: result.value,
      furthest: last.furthest,
      expected: expected
    }
  }

  private static function unsafeUnion(xs : Array<String>, ys : Array<String>) : Array<String> {
    if (xs.length == 0) {
      return ys;
    } else if (ys.length == 0) {
      return xs;
    }

    var result = xs.concat(ys);

    result.sort(function(a, b):Int {
        a = a.toLowerCase();
        b = b.toLowerCase();
        if (a < b) return -1;
        if (a > b) return 1;
        return 0;
    });

    return result;
  }
}