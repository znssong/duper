import Duper.Simp
import Duper.Util.ProofReconstruction

set_option linter.unusedVariables false

namespace Duper
open Std
open RuleM
open SimpResult
open Lean
open Meta
open LitSide

initialize Lean.registerTraceClass `duper.rule.datatypeAcyclicity

/-- Produces a list of (possibly duplicate) constructor subterms for `e` -/
partial def collectConstructorSubterms (e : Expr) : MetaM (Array Expr) := do
  let isConstructor ← matchConstCtor e.getAppFn' (fun _ => pure false) (fun _ _ => pure true)
  if isConstructor then
    let constructorSubterms ← e.getAppArgs.mapM (fun arg => collectConstructorSubterms arg)
    return constructorSubterms.flatten.push e
  else
    return #[e]

/-- Returns `none` if `lit` does not compare constructor subterms, and returns `some litside` if `lit.litside`
    is a subterm of the constructor it is being compared to. Note that `lit.litside` may not itself be a constructor
    (e.g. `xs` is a constructor subterm of `x :: xs`) -/
def litComparesConstructorSubterms (lit : Lit) : MetaM (Option LitSide) := do
  let litTyIsInductive ← matchConstInduct lit.ty.getAppFn' (fun _ => pure false) (fun _ _ => pure true)
  if litTyIsInductive then
    trace[duper.rule.datatypeAcyclicity] "lit.ty {lit.ty} is an inductive datatype"
    -- If `e1` is a constructor subterm of `e2`, then `e1.weight ≤ e2.weight`
    if lit.lhs.weight < lit.rhs.weight then
      let rhsConstructorSubterms ← collectConstructorSubterms lit.rhs
      if rhsConstructorSubterms.contains lit.lhs then return some lhs
      else return none
    else if lit.rhs.weight < lit.lhs.weight then
      let lhsConstructorSubterms ← collectConstructorSubterms lit.lhs
      if lhsConstructorSubterms.contains lit.rhs then return some rhs
      else return none
    else
      if lit.lhs == lit.rhs then return some lhs
      else return none
  else -- `lit.ty` is not an inductive datatype so `lit` cannot be comparing constructor subterms
    trace[duper.rule.datatypeAcyclicity] "lit.ty {lit.ty} is not an inductive datatype"
    return none

def mkDatatypeAcyclicityProof (removedLitNum : Nat) (litSide : LitSide) (premises : List Expr)
  (parents : List ProofParent) (transferExprs : Array Expr) (c : Clause) : MetaM Expr := do
  Meta.forallTelescope c.toForallExpr fun xs body => do
    let cLits := c.lits.map (fun l => l.map (fun e => e.instantiateRev xs))
    let (parentsLits, appliedPremises, transferExprs) ← instantiatePremises parents premises xs transferExprs
    let parentLits := parentsLits[0]!
    let appliedPremise := appliedPremises[0]!
    let mut proofCases : Array Expr := Array.mkEmpty parentLits.size
    for i in [:parentLits.size] do
      let lit := parentLits[i]!
      if i == removedLitNum then -- `lit` is the equality asserting an acyclic constructor
        let proofCase ← Meta.withLocalDeclD `h lit.toExpr fun h => do
          let sizeOfInst ← mkAppOptM ``inferInstanceAs #[← mkAppOptM ``SizeOf #[lit.ty], none]
          let litTyMVar ← mkFreshExprMVar lit.ty
          let abstrLam ← mkLambdaFVars #[litTyMVar] $ ← mkAppOptM ``sizeOf #[some lit.ty, some sizeOfInst, some litTyMVar]
          let sizeOfEq ← mkAppM ``congrArg #[abstrLam, h] -- Has the type `sizeOf lit.lhs = sizeOf lit.rhs`
          -- Need to generate a term of type `¬(sizeOf lit.lhs = sizeOf lit.rhs)`
          let sizeOfEqFalseMVar ← mkFreshExprMVar $ ← mkAppM ``Not #[← inferType sizeOfEq] -- Has the type `¬(sizeOf lit.lhs = sizeOf lit.rhs)`
          let sizeOfEqFalseMVarId := sizeOfEqFalseMVar.mvarId!
          -- **TODO**: Figure out how to assign `sizeOfEqFalseMVar` an actual term
          let proofCase := mkApp2 (mkConst ``False.elim [levelZero]) body $ mkApp sizeOfEqFalseMVar sizeOfEq -- Has the type `body`
          trace[duper.rule.datatypeAcyclicity] "lit: {lit}, lit.ty: {lit.ty}, sizeOfInst: {sizeOfInst}, abstrLam: {abstrLam}, sizeOfEq: {sizeOfEq}"
          trace[duper.rule.datatypeAcyclicity] "sizeOfEqFalseMVar: {sizeOfEqFalseMVar}, proofCase: {proofCase}"
          Meta.mkLambdaFVars #[h] proofCase
        proofCases := proofCases.push proofCase
      else -- `lit` is not the equality to be removed
        let proofCase ← Meta.withLocalDeclD `h lit.toExpr fun h => do
          Meta.mkLambdaFVars #[h] $ ← orIntro (cLits.map Lit.toExpr) i h
        proofCases := proofCases.push proofCase
    let proof ← orCases (parentLits.map Lit.toExpr) proofCases
    Meta.mkLambdaFVars xs $ mkApp proof appliedPremise

/-- Implements the acyclicity rules described in section 6.4 of https://arxiv.org/pdf/1611.02908 -/
def datatypeAcyclicity : MSimpRule := fun c => do
  let c ← loadClause c
  for i in [:c.lits.size] do
    let lit := c.lits[i]!
    match ← litComparesConstructorSubterms lit with
    | some side =>
      if lit.sign then -- `lit` is never true so `lit` can be removed from `c`
        let res := c.eraseIdx i
        let yC ← yieldClause res "datatypeAcyclicity" none -- $ mkDatatypeAcyclicityProof i side
        trace[duper.rule.datatypeAcyclicity] "datatypeAcyclicity applied to {c.lits} to yield {yC.1}"
        return some #[yC]
      else -- `lit` is a tautology so the clause `c` can simply be removed
        trace[duper.rule.datatypeAcyclicity] "datatypeAcyclicity applied to remove {c.lits}"
        return some #[]
    | none => continue
  return none
