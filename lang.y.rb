class Parser
  prechigh
    left '+'
  preclow
  token WORD INT TRUE FALSE UNIT STRING
  options no_result_var
  rule
  start: stmts { [val[0]].flatten }

  stmts : stmt | stmt ";" stmts { [val[0], val[2]] }
  stmt :  expr_0 | def_ 

  def_ : "def" WORD "=" expr_0 { Def.new(val[1], val[3]) }

  expr_0 : fun | if_ | expr_1
  expr_1 : bin | expr_2 
  expr_2 : app | expr_3
  expr_3 : atom

  if_ : "if" expr_0 "then" expr_0 "else" expr_0 { If.new(val[1], val[3], val[5]) }
  fun : "fun" WORD  ":" typ_0 "=>" expr_0 { Fun.new(val[1], val[3], val[5]) }
  app : expr_2 expr_3 { App.new(val[0], val[1]) }
  bin : expr_1 "+" expr_1 { Bin.new("+", val[0], val[2]) }
  atom : WORD { val[0].to_sym } | const | hole | "(" expr_0 ")" { val[1] } | list
  list : "[]" | "[" items "]" { [val[1]].flatten }
  items : expr_0 | expr_0 "," items { [val[0], val[2]] }
  const : INT | TRUE { true } | FALSE { false } | UNIT | STRING 
  hole : "?" { :hole }

  typ_0 : t_arrow | typ_1
  typ_1 : t_app | typ_2
  typ_2 : t_atom

  t_app : typ_1 typ_2
  t_atom : t_const | "(" typ_0 ")" { val[1] }
  t_const : "int" { :t_int } | "list" typ_2 { [:t_list, val[1]] }
  t_arrow : typ_1 "->" typ_0 { [:t_arrow, val[0], val[2]] }
end

---- inner

CONSTS = %w[true false unit]
KEYWORDS = %w[def fun int if then else list]
SYMBOLS = %w(=> = [ ] ( ) : -> + - * / ; , ? $)
            .map { |x| Regexp.quote(x) }

def readstring(s)
  acc = []
  loop do
    x = s.scan_until(/"|\"/)
    fail "unterminated string \"#{str}" if x.nil?
    if x.end_with? '\"'
      acc << x
    else
      acc << x[..-2]
      break
    end
  end
  return acc.join("")
end

def tokenize(str)
  require 'strscan'
  result = []
  s = StringScanner.new(str)
  until s.empty?
    case
    when s.scan(/\s+/)
    when s.scan(/#/)
      s.skip_until(/$/)
    when tok = s.scan(/\b(#{CONSTS.join("|")})\b/)
      result << [tok.upcase.to_sym, tok.to_sym]
    when tok = s.scan(/\b(#{KEYWORDS.join("|")})\b/)
      result << [tok, nil]
    when tok = s.scan(/#{SYMBOLS.join("|")}/)
      result << [tok, nil]
    when tok = s.scan(/\d+/)
      result << [:INT, tok.to_i]
    when tok = s.scan(/\w+((\.|::)\w+)*/)
      result << [:WORD, tok]
    when tok = s.scan(/"/)
      result << [:STRING, readstring(s)]
    else
      fail "bad token #{s.peek 10}"
    end
  end
  result << [false, false]
  result
end

def parse(str)
  @tokens = tokenize(str)
  Interpreter.new(do_parse)
end

def next_token
  @tokens.shift
end

---- header
class Fun < Struct.new :arg, :typ, :body; end
class App < Struct.new :f, :arg; end
class If < Struct.new :cond, :then_, :else_; end
class Bin < Struct.new :op, :a, :b; end
class Def < Struct.new :name, :value; end

class Interpreter
  attr_accessor :ast
  def initialize(ast)
    @ast = ast
  end

  def eval
    eval_stmts(@ast, {})
  end

  private

  def eval_stmts(exprs, env)
    exprs.each do |expr|
      eval_stmt(expr, env)
    end
  end

  def eval_stmt(stmt, env)
    case stmt
    when Def
      value = eval_expr(stmt.value, env)
      env[stmt.name.to_sym] = value
    else
      eval_expr(stmt, env)
    end

    nil
  end

  def eval_expr(expr, env)
    case expr
    when Integer, String, TrueClass, FalseClass
      return expr
    when Array
      expr.map {|item| eval_expr(item, env) }
    when Fun
      return ->(x) { eval_expr(expr.body, env.merge({ expr.arg.to_sym => x })) }
    when If
      c, env = eval_expr(expr.cond, env)
      if c
        eval_expr(expr.then_, env)
      else
        eval_expr(expr.else_, env)
      end
    when Symbol
      env[expr]
    when App
      case expr.f
      when Symbol
        if env.key?(expr.f)
          f = env[expr.f]
          arg = eval_expr(expr.arg, env)
          eval_expr(App.new(f, arg), env)
        else
          arg = eval_expr(expr.arg, env)
          fname = expr.f.to_s
          if fname.include? "::"
            namespace, _, name = fname.partition(".")
            result = Object.const_get(namespace).send(name, arg)
          else
            result = send("#{expr.f}".to_sym, arg)
          end
          result
        end
      when Fun
        arg = eval_expr(expr.arg, env)
        f = eval_expr(expr.f, env)
        f.call(arg)
      else
        fail "bad application #{expr}"
      end
    else
      fail "unknown expression #{expr}"
    end
  end
end

---- footer
interp = Parser.new.parse(<<END
puts (if true then 1 else 0);
def x = 100;
puts x;

# lets try some requests
require "uri";
require "net/http";
def uri = URI("http://google.com");
puts uri;
p (Net::HTTP.get_response uri);
(fun x : list (int -> int) => p x) 1;
p [1,2,3,4]
END
)

# interp.ast.each(&method(:puts))
interp.eval
