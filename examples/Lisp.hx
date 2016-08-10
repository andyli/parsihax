package examples;

import parsihax.Parser as P;

class Lisp {
  public static function main() {
    // A little helper to wrap a parser with optional whitespace.
    function spaced(parser) {
      return P.optWhitespace().then(parser).skip(P.optWhitespace());
    }

    // We need to use `P.ref` here because the other parsers don't exist yet. We
    // can't just declare this later though, because `LList` references this parser!
    var LExpression = P.ref();

    // The basic parsers (usually the ones described via regexp) should have a
    // description for error message purposes.
    var LSymbol = P.regexp(~/[a-zA-Z_-][a-zA-Z0-9_-]*/).desc('symbol');
    var LNumber = P.regexp(~/[0-9]+/).map(function (result) { return Std.parseInt(result); }).desc('number');

    // `.then` throws away the first value, and `.skip` throws away the second
    // `.value, so we're left with just the `spaced(LExpression).many()` part as the
    // `.yielded value from this parser.
    var LList =
      P.string('(')
        .then(spaced(LExpression).many())
        .skip(P.string(')'));

    LExpression.set(P.lazy(function() {
        return P.alt([
          LSymbol,
          LNumber,
          LList
        ]);
      }));

    // Let's remember to throw away whitespace at the top level of the parser.
    var lisp = spaced(LExpression);

    ///////////////////////////////////////////////////////////////////////

    var text = '( abc 89 ( c d 33 haleluje) )';

    switch(lisp.parse(text)) {
      case Success(value):
        trace(value);
      case Failure(index, expected):
        trace(P.formatError(text, index, expected));
    }
  }
}