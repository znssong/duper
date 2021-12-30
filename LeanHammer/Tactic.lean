import Lean
import LeanHammer.Saturate
import LeanHammer.Unif

open Lean
open Lean.Meta
open Schroedinger
open ProverM


namespace Lean.Elab.Tactic

syntax (name := prover) "prover" : tactic


partial def printProof (state : ProverM.State) : TacticM Unit := do
  let rec go c : TacticM Unit := do
    let info ← getClauseInfo! c
    let parentInfo ← info.proof.parents.mapM (fun pp => getClauseInfo! pp.clause) 
    let parentIds ← parentInfo.map fun info => info.number
    trace[Prover.debug] "Clause #{info.number} (by {info.proof.ruleName} {parentIds}): {c}"
    for proofParent in info.proof.parents do
      go proofParent.clause
  go Clause.empty
where 
  getClauseInfo! (c : Clause) : TacticM ClauseInfo := do
    let some ci ← state.allClauses.find? c
      | throwError "clause info not found: {c}"
    ci

partial def applyProof (state : ProverM.State) : TacticM (List MVarId) := do
  let (skolemsFVars, skolemMVars) ← state.lctx.decls.foldlM (init := (#[], #[])) fun r decl? => match decl? with
    | some decl => do 
      (r.1.push (mkFVar decl.fvarId),
        r.2.push (← mkFreshExprMVar decl.type))
    | none      => r
  let rec go c : TacticM (Expr × List MVarId) := do
    let info ← getClauseInfo! c
    let parentInfo ← info.proof.parents.mapM (fun pp => getClauseInfo! pp.clause) 
    let parentIds ← parentInfo.map fun info => info.number
    let target ← info.proof.parents.foldrM
      (fun proofParent target => mkArrow proofParent.clause.toForallExpr target)
      c.toForallExpr
    let target ← withLCtx state.lctx #[] do mkLambdaFVars skolemsFVars target
    let target ← mkAppN target skolemMVars
    let mvar ← mkFreshExprMVar target (userName := s!"Clause #{info.number} (by {info.proof.ruleName} {parentIds})")
    let mut goals := [mvar.mvarId!]
    let mut proof := mvar
    for proofParent in info.proof.parents do
      let (parentProof, newGoals) ← go proofParent.clause
      goals := goals ++ newGoals
      proof := mkApp proof parentProof
    return (proof, goals)
  let (proof, goals) ← go Clause.empty
  assignExprMVar (← getMainGoal) proof
  return skolemMVars.toList.map Expr.mvarId! ++ goals
where 
  getClauseInfo! (c : Clause) : TacticM ClauseInfo := do
    let some ci ← state.allClauses.find? c
      | throwError "clause info not found: {c}"
    ci

def collectAssumptions : TacticM (Array Expr) := do
  let mut formulas := #[]
  for fVarId in (← getLCtx).getFVarIds do
    let ldecl ← getLocalDecl fVarId
    unless ldecl.binderInfo.isAuxDecl ∨ not (← inferType ldecl.type).isProp do
      formulas := formulas.push ldecl.type
  return formulas

@[tactic prover]
partial def evalProver : Tactic
| `(tactic| prover) => do
  let startTime ← IO.monoMsNow
  let formulas ← collectAssumptions
  trace[Meta.debug] "{formulas}"
  let (_, state) ← ProverM.runWithExprs ProverM.saturate formulas
  match state.result with
  | Result.contradiction => do
      printProof state
      let goals ← applyProof state
      setGoals $ goals
      trace[Prover.debug] "Time: {(← IO.monoMsNow) - startTime}ms {(← getUnsolvedGoals).length}"
  | Result.saturated => 
    trace[Prover.debug] "Final Active Set: {state.activeSet.toArray}"
    -- trace[Prover.debug] "supMainPremiseIdx: {state.supMainPremiseIdx}"
    throwError "Prover saturated."
  | Result.unknown => throwError "Prover was terminated."
| _ => throwUnsupportedSyntax

end Lean.Elab.Tactic

