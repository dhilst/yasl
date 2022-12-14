require "readline"
require "./parser"

# Receives an AST and return a simpler AST with only
# Val, App, Lamb, Symbol (denoting variables) and constants
class Desuger
  def desugar(stmts)
    stmts.map(&method(:desugar_stmt)).flatten
  end

  private

  def lamb(*args_body)
    *args, arg, body = args_body
    init = Lamb.new(arg, nil, body)
    args.reverse.reduce(init) do |acc, arg|
      Lamb.new(arg, nil, acc)
    end
  end

  def app(*exprs)
    e1, e2, *exprs = exprs
    init = App.new(e1, e2)
    exprs.reduce(init) do |acc, arg|
      App.new(acc, arg)
    end
  end

  def desugar_stmt(stmt)
    case stmt
    when DataType
      ctrs = stmt.ctrs.map(&:name)
      stmt.ctrs.map.with_index do |ctr, idx|
        if ctr.args.nil?
          # none ~> let none = fun some => fun none => none
          Val.new(ctr.name, lamb(*[*ctrs, ctr.name]))
        else
          # some x ~ let some = fun x => fun some => fun none => some x
          Val.new(ctr.name, lamb(*[*ctr.args, *ctrs, app(ctr.name, *ctr.args)]))
        end
      end
    when Val
      Val.new(stmt.name, desugar_expr(stmt.value))
    else
      desugar_expr(stmt)
    end
  end

  def desugar_expr(expr)
    case expr
    when Integer, Symbol, TrueClass, FalseClass, If
      expr
    when App
      App.new(desugar_expr(expr.f), desugar_expr(expr.arg))
    when Lamb
      Lamb.new(expr.arg, expr.typ, desugar_expr(expr.body))
    when Let
      # let x = e1 in e2 ~> (fun x => e2) e1
      App.new(
        Lamb.new(expr.x, nil, desugar_expr(expr.e2)),
        desugar_expr(expr.e1))
    when Match
      # match some x with | some y => y | none => z
      # ~>
      # (some x) (fun y => y) z
      branches = expr.patterns.map do |pat|
        case pat.pat
        when Symbol
          # none => ... ~> ...
          pat.body
        when Array
          # some x => ... ~> fun x => ...
          # pair a b => ... ~> fun a => fun b => ...
          _, *args = pat.pat
          lamb(*args, pat.body)
        else
          fail "bad match branch #{pat} in #{expr}"
        end
      end
      app(expr.scrutinee, *branches)
    else
      fail "desugar error : bad expr #{expr}"
    end
  end
end

class Unparser
  def unparse(stmts)
    stmts.map(&method(:unparse_stmt)).join(";\n\n")
  end

  private

  def ident(i, str)
    str.split("\n").map do |str|
      "#{' ' * i}#{str}"
    end.join("\n")
  end

  def unparse_stmt(stmt)
    case stmt
    when DataType
      case stmt.args
      when Array
        "data #{stmt.name} #{stmt.args.join(' ')} = #{unparse_ctrs(stmt.ctrs)}"
      when NilClass
        "data #{stmt.name} = #{unparse_ctrs(stmt.ctrs)}"
      end
    when Val
      "val #{stmt.name} =\n#{ident(2, unparse_expr(stmt.value))}"
    else
      unparse_expr(stmt)
    end
  end

  def unparse_ctrs(ctrs)
    ctrs.map(&method(:unparse_ctr)).join(" | ")
  end

  def unparse_ctr(ctr)
    fail "unparse error : not a ctr #{ctr}" unless ctr.is_a? Ctr
    "#{ctr.name} #{ctr.args&.join(' ')}"
  end

  def unparse_expr(expr)
    case expr
    when Integer, Symbol, TrueClass, FalseClass
      expr.to_s
    when Let
      "let #{expr.x} = #{unparse_expr(expr.e1)} in #{unparse_expr(expr.e2)}"
    when Lamb
      "fun #{expr.arg} => #{unparse_expr(expr.body)}"
    when App
      case expr.arg
      when App, Lamb, Let
        "#{unparse_expr(expr.f)} (#{unparse_expr(expr.arg)})"
      else
        case expr.f
        when Lamb
          "(#{unparse_expr(expr.f)}) #{unparse_expr(expr.arg)}"
        else
          "#{unparse_expr(expr.f)} #{unparse_expr(expr.arg)}"
        end
      end
    when Match
      "match #{unparse_expr(expr.scrutinee)} with\n" +
        unparse_match_patterns(expr.patterns)
    when If
      "if #{unparse_expr(expr.cond)}\n" +
        "then #{unparse_expr(expr.then_)}\n" +
        "else #{unparse_expr(expr.else_)}"
    else
      fail "unparse error : bad expression #{expr}"
    end
  end

  def unparse_match_patterns(patterns)
    patterns.map(&method(:unparse_match_pattern)).join("\n") + "\nend"
  end

  def unparse_match_pattern(pattern)
    case pattern.pat
    when Symbol
      "| #{pattern.pat} => #{unparse_expr(pattern.body)}"
    when Array
      "| #{pattern.pat.join(' ')} => #{unparse_expr(pattern.body)}"
    else
      fail "bad pattern pat #{pattern}"
    end
  end
end

class UFun < Struct.new :name, :args
  def to_s
    return "#{name}" if args.empty?

    case name
    when :arrow
      fail "invalid arrow it should have exactly 2 arguments, but found #{args}" if args.size != 2
      if args[0].is_a?(UFun) and args[0].name == :arrow
        "(#{args[0]}) -> #{args[1]}"
      else
        "#{args[0]} -> #{args[1]}"
      end
    else
      "#{name} #{args.join(' ')}"
    end
  end
end

class UVar
  @@next_letter = "a"

  attr_reader :letter

  def initialize(letter)
    @letter = letter.dup
  end

  def to_s
    "#{@letter}"
  end

  def self.fresh!
    l = @@next_letter
    @@next_letter.next!
    UVar.new(l)
  end

  def self.reset
    @@next_letter = "a"
  end

  def ==(b)
    fail "invalid comparison #{self} == #{b}" unless b.is_a? UVar
    @letter == b.letter
  end
end

class Unifier
  def self.unify(problems)
    return [] if problems.empty?
    p, *problems = problems
    a, b = p
    case [a,b].map(&:class)
    when [UVar, UVar]
      if a == b
        unify(problems)
      else
        problems = problems.map do |k, v|
          [subst(a, b, k), subst(a, b, v)]
        end
        [[a, b]] + unify(problems)
      end
    when [UFun, UVar]
      unify([[b, a]] + problems) # swap
    when [UFun, UFun]
      fail "unification error #{a} <> #{b}" if a.name != b.name or a.args.size != b.args.size
      unify(a.args.zip(b.args) + problems)
    when [UVar, UFun]
      fail "unification error #{a} occurs in #{b}" if occurs(a, b)
      problems = problems.map do |k, v|
        [subst(a, b, k), subst(a, b, v)]
      end
      [[a, b]] + unify(problems)
    else
      fail "invalid argument #{a.class} #{b.class}"
    end
  end

  def self.subst_env(subs, env)
    env.map do |k, v|
      [k, substm(subs, v)]
    end.to_h
  end

  def self.substm(subs, term)
    subs.reduce(term) do |term, s|
      k, v = s
      subst(k, v, term)
    end
  end

  def self.subst(k, v, term)
    case term
    when UFun
      UFun.new(term.name, term.args.map {|arg| subst(k, v, arg)})
    when UVar
      return v if term == k
      term
    end
  end

  def self.occurs(a, b)
    fail "invalid argument #{a} #{b}" unless a.is_a? UVar
    case b
    when UVar
      a == b
    when UFun
      b.args.any? do |barg|
        occurs(a, barg)
      end
    else
      fail "invalid argument, #{b}"
    end
  end
end

class TypeScheme < Struct.new :args, :typ
  def instantiate
    fresh_vars = args.map do |arg|
      [arg, UVar.fresh!]
    end
    Unifier.substm(fresh_vars, typ)
  end

  def self.generalize(typ, env)
    vs = vars(typ).reject {|v| env.has_value? v}
    TypeScheme.new(vs, typ)
  end

  def self.vars(typ)
    case typ
    when UVar
      [typ]
    when UFun
      typ.args.map do |arg|
        vars(arg)
      end.flatten.uniq.sort_by(&:to_s)
    else
      fail "invalid argument #{typ}"
    end
  end

  def to_s
    return typ.to_s if args.empty?
    "forall #{args.join(' ')} . #{typ}"
  end
end

class Typechecker
  def typecheck(stmts)
    env = global_env
    stmts.map do |stmt|
      UVar.reset
      stmt, t = typecheck_stmt(stmt, env)
      [stmt, t]
    end
  end

  def typecheck_stmt_repl(stmt, env)
    env = global_env if env.empty?
    stmt, t = typecheck_stmt(stmt, env)
    [stmt, t, env]
  end

  private

  def arrow(*args)
    *args, a, b = args
    init = UFun.new(:arrow, [a, b])
    args.reverse.reduce(init) do |acc, arg|
      UFun.new(:arrow, [arg, acc])
    end
  end

  def global_env
    int = UFun.new(:int, [])
    nilt = UFun.new(:nil, [])
    bool = UFun.new(:bool, [])
    a = UVar.fresh!
    b = UVar.fresh!
    env = {
      unify: TypeScheme.new([a], arrow(a, a, a)),
      eq: TypeScheme.new([a], arrow(a, a, bool)),
      sub: TypeScheme.new([], arrow(int, int, int)),
      add: TypeScheme.new([], arrow(int, int, int)),
      mul: TypeScheme.new([], arrow(int, int, int)),
      not: TypeScheme.new([], arrow(bool, bool)),
      puts: TypeScheme.new([a], arrow(a, nilt)),
    }
    env[:fix] = TypeScheme.new([a, b], arrow(arrow(arrow(a, b), a, b), a, b)) \
                              if ENV["ENABLE_FIXPOINT"]
    env
  end

  def typecheck_stmt(stmt, env)
    case stmt
    when Val
      t, val, s = typecheck_expr(stmt.value, env)
      t = Unifier.substm(s, t)
      t = TypeScheme.generalize(t, env)
      env[stmt.name] = t
      [Val.new(stmt.name, val), t, env]
    else
      t, stmt, s = typecheck_expr(stmt, env)
      t = Unifier.substm(s, t)
      t = TypeScheme.new([], t)
      [stmt, t, env]
    end
  end

  def typecheck_expr(expr, env)
    case expr
    when String, NilClass
      name = expr.class.name.downcase.sub(/class/, "")
      [UFun.new(name, []), expr, []]
    when Integer
      [UFun.new(:int, []), expr, []]
    when TrueClass, FalseClass
      [UFun.new(:bool, []), expr, []]
    when Symbol
      fail "unbound variable #{expr}" unless env.key? expr
      [env[expr].instantiate, expr, []]
    when Lamb
      if expr.typ
        targ = expr.typ
      else
        targ = UVar.fresh!
      end
      newenv = env.merge({ expr.arg => TypeScheme.new([], targ) })
      tbody, body, sbody = typecheck_expr(expr.body, newenv)
      typ = UFun.new(:arrow, [targ, tbody])
      typ = Unifier.substm(sbody, typ)
      lamb = Lamb.new(expr.arg, typ.args[0], body)
      [typ, lamb, sbody]
    when App
      tfunc, f, sfunc = typecheck_expr(expr.f, env)
      targ, arg, sarg = typecheck_expr(expr.arg, env)
      tfunc2 = UFun.new(:arrow, [targ, UVar.fresh!])
      sfunc2 = unify(expr, [[tfunc, tfunc2]] + sfunc + sarg)
      tresult = Unifier.substm(sfunc2, tfunc2)
      app = App.new(f, arg)
      [tresult.args[1], app, sfunc2]
    when If
      tcond, cond, scond = typecheck_expr(expr.cond, env)
      Unifier.unify([[tcond, UFun.new(:bool, [])]])
      tthen, then_, sthen = typecheck_expr(expr.then_, env)
      telse, else_, selse = typecheck_expr(expr.else_, env)
      sthenelse = unify(expr, [[tthen, telse]] + scond + sthen + selse)
      tif = Unifier.substm(sthenelse, tthen)
      if_ = If.new(cond, then_, else_)
      [tif, if_, sthenelse]
    else
      # PS in [let x = ... in ...], [x] is not universally
      # quantified. [let] is just sugar for application, only [val x =
      # ...] constructs are universally quantified.
      fail "invalid argument #{expr}"
    end
  end

  def unify(expr, args)
    Unifier.unify(args)
  rescue StandardError => e
    raise e unless e.to_s.include?("unification error")
    fail "type error #{e} in `#{expr}'"
  end
end

class Interpreter
  def eval(stmts)
    eval_stmts(stmts, global_env)
  end

  def eval_stmt_repl(stmt, env)
    env = global_env if env.empty?
    stmt, env = eval_stmt(stmt, env)
  end

  private

  def fix(f, x)
    fixm = method(:fix).curry
    f.call(fixm.call(f)).call(x)
  end

  def global_env
    {
      unify: ->(a, b){ b }.curry,
      puts: method(:puts),
      fix: method(:fix).curry,
      add: ->(a, b) { a + b }.curry,
      mul: ->(a, b) { a * b }.curry,
      sub: ->(a, b) { a - b }.curry,
      eq: ->(a, b) { a == b }.curry,
      not: ->(a) { not a }
    }
  end

  def eval_stmts(stmts, env)
    stmts.each do |stmt|
      eval_stmt(stmt, env)
    end
  end

  def eval_stmt(stmt, env)
    case stmt
    when Val
      fail "bad name #{stmt.name} in #{stmt}" unless stmt.name.is_a? Symbol
      env[stmt.name] = stmt.value
      [stmt.value, env]
    else
      [eval_expr(stmt, env), env]
    end
  end

  def eval_expr(expr, env)
    case expr
    when App
      f = eval_expr(expr.f, env)
      arg = eval_expr(expr.arg, env)
      case f
      when Proc, Method
        eval_expr(f.call(arg), env)
      else
        fail "bad application #{expr}"
      end
    when Lamb
      ->(x) { eval_expr(expr.body, env.merge({expr.arg => x})) }
    when Symbol
      fail "Unbounded symbol #{expr}" unless env.key? expr
      eval_expr(env[expr], env)
    when If
      cond = eval_expr(expr.cond, env)
      if cond
        eval_expr(expr.then_, env)
      else
        eval_expr(expr.else_, env)
      end
    when Method, Proc, Integer, String, NilClass, TrueClass, FalseClass # puts return nil
      expr
    else
      fail "bad expression #{expr.class} #{expr}"
    end
  rescue StandardError => e
    puts "error with #{expr}"
    raise e
  end
end

class REPL
  def initialize
    @parser = Parser.new
    @desuger = Desuger.new
    @typechecker = Typechecker.new
    @interpreter = Interpreter.new
    @tenv = {}
    @ienv = {}
  end

  def run
    loop do
      line = Readline.readline("> ", true)
      next if line.nil?
      next if line.empty?
      break if line == "exit"
      run_stmt_text(line)
      UVar.reset
    rescue StandardError => e
      puts "Error : #{e}"
    end
  end

  private 

  def run_stmt_text(stmt_text)
    ast = @parser.parse(stmt_text)
    ast = @desuger.desugar(ast)
    ast.each do |stmt|
      stmt, t, @tenv = @typechecker.typecheck_stmt_repl(stmt, @tenv)
      value,  @ienv = @interpreter.eval_stmt_repl(stmt, @ienv)
      if [Proc, Method].include?(value.class) || stmt.is_a?(Val)
        puts "#{stmt} : #{t}"
      else 
        puts "#{value} : #{t}"
      end
    end
  end
end

def main
  REPL.new.run
end

main
