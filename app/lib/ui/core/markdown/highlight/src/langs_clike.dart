import 'clike.dart';
import 'model.dart';
import 'words.dart';

const _kw = TokenKind.keyword,
    _ty = TokenKind.type,
    _co = TokenKind.constant;

LineHighlighter dartHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: 'abstract as assert async await break case catch class const '
            'continue covariant default deferred do else enum export extends '
            'extension external factory final finally for if implements import '
            'in interface is late library mixin new operator part required '
            'rethrow return static super switch sync this throw try typedef '
            'var while with yield',
        _ty: 'int double num bool String List Map Set Object Iterable Future '
            'Stream Function Type dynamic void Never Null Duration DateTime '
            'Uri Record Symbol',
        _co: 'true false null',
      }),
      soft: Words({
        _kw: 'get set on show hide when base sealed of',
      }),
      lineSlash: true,
      block: true,
      nested: true,
      tripleDq: true,
      tripleSq: true,
      prefixes: 'r',
      maxPrefix: 1,
      atAttribute: true,
    ));

const _jsKeywords = 'async await break case catch class const continue '
    'debugger default delete do else export extends finally for function if '
    'import in instanceof new return super switch this throw try typeof var '
    'void while with yield let static';

LineHighlighter javascriptHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: '$_jsKeywords constructor',
        _co: 'true false null undefined NaN Infinity',
      }),
      soft: Words({_kw: 'of from as get set'}),
      lineSlash: true,
      block: true,
      backtick: Backtick.template,
      regex: true,
      atAttribute: true,
    ));

LineHighlighter typescriptHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: '$_jsKeywords constructor enum interface implements package '
            'private protected public readonly abstract declare namespace '
            'keyof satisfies override infer asserts',
        _ty: 'string number boolean any unknown never object symbol bigint',
        _co: 'true false null undefined NaN Infinity',
      }),
      soft: Words({_kw: 'of from as get set type module is'}),
      lineSlash: true,
      block: true,
      backtick: Backtick.template,
      regex: true,
      atAttribute: true,
    ));

LineHighlighter pythonHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: 'and as assert async await break class continue def del elif '
            'else except finally for from global if import in is lambda '
            'nonlocal not or pass raise return try while with yield',
        _ty: 'int float str bool bytes list dict set tuple frozenset object '
            'complex bytearray',
        _co: 'True False None Ellipsis NotImplemented',
      }),
      soft: Words({_kw: 'match case type'}),
      lineHash: true,
      tripleDq: true,
      tripleSq: true,
      prefixes: 'rRbBfFuU',
      maxPrefix: 2,
      atAttribute: true,
    ));

LineHighlighter rustHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: 'as async await break const continue crate dyn else enum extern '
            'fn for if impl in let loop match mod move mut pub ref return '
            'self static struct super trait type unsafe use where while union',
        _ty: 'i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 '
            'bool char str String Vec Option Result Box Rc Arc Self',
        _co: 'true false None Some Ok Err',
      }),
      lineSlash: true,
      block: true,
      nested: true,
      singleQuote: SingleQuote.char,
      multilineDq: true,
      prefixes: 'bc',
      maxPrefix: 1,
      rustRaw: true,
      lifetimes: true,
      macroBang: true,
      rustAttr: true,
    ));

LineHighlighter goHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: 'break case chan const continue default defer else fallthrough '
            'for func go goto if import interface map package range return '
            'select struct switch type var',
        _ty: 'bool byte complex64 complex128 error float32 float64 int int8 '
            'int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 '
            'uintptr any comparable',
        _co: 'true false nil iota',
      }),
      lineSlash: true,
      block: true,
      singleQuote: SingleQuote.char,
      backtick: Backtick.raw,
      upperCall: true,
    ));

const _cKeywords = 'auto break case const continue default do else enum '
    'extern for goto if inline register restrict return sizeof static struct '
    'switch typedef union volatile while';

const _cTypes = 'char double float int long short signed unsigned void bool '
    '_Bool size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t '
    'int64_t uint8_t uint16_t uint32_t uint64_t wchar_t FILE';

LineHighlighter cHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: _cKeywords,
        _ty: _cTypes,
        _co: 'true false NULL',
      }),
      lineSlash: true,
      block: true,
      singleQuote: SingleQuote.char,
      directives: Directives.lineStart,
      prefixes: 'LuU8',
      maxPrefix: 2,
    ));

LineHighlighter cppHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: '$_cKeywords alignas alignof and asm catch class constexpr '
            'const_cast consteval constinit decltype delete dynamic_cast '
            'explicit export friend mutable namespace new noexcept not '
            'operator or private protected public reinterpret_cast '
            'static_assert static_cast template this thread_local throw try '
            'typeid typename using virtual override final concept requires '
            'co_await co_return co_yield',
        _ty: '$_cTypes string wstring string_view vector map set '
            'unordered_map unordered_set array pair tuple optional variant '
            'unique_ptr shared_ptr weak_ptr function char8_t char16_t '
            'char32_t',
        _co: 'true false NULL nullptr',
      }),
      lineSlash: true,
      block: true,
      singleQuote: SingleQuote.char,
      directives: Directives.lineStart,
      prefixes: 'LuU8',
      maxPrefix: 2,
    ));

LineHighlighter javaHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: 'abstract assert break case catch class const continue default '
            'do else enum extends final finally for goto if implements '
            'import instanceof interface native new package private '
            'protected public return static strictfp super switch '
            'synchronized this throw throws transient try volatile while',
        _ty: 'boolean byte char short int long float double void var String '
            'Object',
        _co: 'true false null',
      }),
      soft: Words({_kw: 'record sealed permits yield non-sealed'}),
      lineSlash: true,
      block: true,
      singleQuote: SingleQuote.char,
      tripleDq: true,
      atAttribute: true,
    ));

LineHighlighter kotlinHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: 'as break class continue do else for fun if in interface is '
            'object package return super this throw try typealias val var '
            'when while by catch constructor finally import init',
        _ty: 'Int Long Short Byte Float Double Boolean Char String Unit Any '
            'Nothing Array',
        _co: 'true false null',
      }),
      soft: Words({
        _kw: 'abstract actual annotation companion const crossinline data '
            'enum expect external final infix inline inner internal '
            'lateinit noinline open operator out override private protected '
            'public reified sealed suspend tailrec vararg value get set '
            'where',
      }),
      lineSlash: true,
      block: true,
      nested: true,
      singleQuote: SingleQuote.char,
      backtick: Backtick.ident,
      tripleDq: true,
      atAttribute: true,
    ));

LineHighlighter swiftHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: 'associatedtype class deinit enum extension fileprivate func '
            'import init inout internal let open operator private protocol '
            'public rethrows static struct subscript typealias var break '
            'case catch continue default defer do else fallthrough for guard '
            'if in repeat return throw switch where while as await async is '
            'self super throws try',
        _ty: 'Int Int8 Int16 Int32 Int64 UInt Double Float String Bool '
            'Character Array Dictionary Set Optional Void Any AnyObject '
            'Self',
        _co: 'true false nil',
      }),
      soft: Words({
        _kw: 'some any get set willSet didSet lazy final weak mutating '
            'nonmutating override convenience required indirect '
            'nonisolated actor macro unowned dynamic',
      }),
      lineSlash: true,
      block: true,
      nested: true,
      singleQuote: SingleQuote.none,
      backtick: Backtick.ident,
      tripleDq: true,
      atAttribute: true,
      directives: Directives.anywhere,
    ));

LineHighlighter sqlHighlighter() => CLikeHighlighter(CLikeSpec(
      words: Words({
        _kw: 'select from where and or not in is like ilike between exists '
            'insert into values update set delete create alter drop table '
            'index view database schema primary key foreign references '
            'unique default check constraint join inner outer left right '
            'full cross on using group by order having limit offset union '
            'all distinct as case when then else end asc desc with '
            'recursive returning begin commit rollback transaction grant '
            'revoke truncate if cascade add column rename to explain '
            'analyze over partition window rows range unbounded preceding '
            'following current row fetch next only escape similar any some '
            'except intersect lateral temporary temp replace function '
            'trigger procedure declare for each execute do language '
            'returns return vacuum pragma conflict nothing materialized '
            'extension collate natural',
        _ty: 'int integer bigint smallint tinyint mediumint serial bigserial '
            'boolean bool text varchar char character numeric decimal float '
            'real double precision date time timestamp timestamptz interval '
            'uuid json jsonb blob bytea array money varbinary datetime',
        _co: 'true false null',
      }, ignoreCase: true),
      lineDash: true,
      block: true,
      multilineSq: true,
      doubledQuote: true,
      backslash: false,
      dqIsIdentifier: true,
      backtick: Backtick.ident,
      capsType: false,
    ));
