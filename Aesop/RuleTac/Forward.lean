/-
Copyright (c) 2022 Jannis Limperg. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jannis Limperg
-/

import Aesop.RuleTac.Basic

open Lean
open Lean.Meta

namespace Aesop.RuleTac

private partial def makeForwardHyps (e : Expr)
    (immediate : UnorderedArraySet Nat) (collectUsedHyps : Bool) :
    MetaM (Array Expr × Array FVarId) :=

  withNewMCtxDepth do
    let (argMVars, binderInfos, _) ← forallMetaTelescopeReducing (← inferType e)

    let app := mkAppN e argMVars
    let mut instMVars := Array.mkEmpty argMVars.size
    let mut immediateMVars := Array.mkEmpty argMVars.size
    for i in [:argMVars.size] do
      let mvarId := argMVars[i]!.mvarId!
      if immediate.contains i then
        immediateMVars := immediateMVars.push mvarId
      else if binderInfos[i]!.isInstImplicit then
        instMVars := instMVars.push mvarId

    loop app instMVars immediateMVars 0 #[] #[] #[]
  where
    loop (app : Expr) (instMVars : Array MVarId) (immediateMVars : Array MVarId)
        (i : Nat) (proofsAcc : Array Expr) (currentUsedHyps : Array FVarId)
        (usedHypsAcc : Array FVarId) :
        MetaM (Array Expr × Array FVarId) := do
      if h : i < immediateMVars.size then
        let mvarId := immediateMVars.get ⟨i, h⟩
        let type ← mvarId.getType
        (← getLCtx).foldlM (init := (proofsAcc, usedHypsAcc)) λ s@(proofsAcc, usedHypsAcc) ldecl =>
          if ldecl.isImplementationDetail then
            pure s
          else
            withoutModifyingState do
              if ← isDefEq ldecl.type type then
                mvarId.assign (mkFVar ldecl.fvarId)
                let currentUsedHyps :=
                  if collectUsedHyps then
                    currentUsedHyps.push ldecl.fvarId
                  else
                    currentUsedHyps
                loop app instMVars immediateMVars (i + 1) proofsAcc
                    currentUsedHyps usedHypsAcc
              else
                pure s
      else
        for instMVar in instMVars do
          instMVar.withContext do
            let inst ← synthInstance (← instMVar.getType)
            instMVar.assign inst
        let proofsAcc := proofsAcc.push (← abstractMVars app).expr
        let usedHypsAcc := usedHypsAcc ++ currentUsedHyps
        return (proofsAcc, usedHypsAcc)

/-
Forward rules must only succeed once for each combination of immediate
hypotheses; otherwise any forward rule could be applied infinitely often (if
it can be applied at all). We use the following scheme to ensure this:

- Whenever we add a hypothesis `h : T` as an instance of a forward rule, we also
  add an `implDetail` decl `h' : T`.
- Before we add a hypothesis `h : T`, we check whether there is already an
  `implDetail` `h' : T`. If so, `h` is not added.

This scheme ensures that forward rules never add more than one hypothesis of
any given type. `h'` is added as an `implDetail`, rather than as a regular
hypothesis, to ensure that future rule applications do not change its type.
-/

def forwardHypPrefix := `_fwd

def mkFreshForwardHypName : MetaM Name :=
  mkFreshIdWithPrefix forwardHypPrefix

def isForwardHypName (n : Name) : Bool :=
  forwardHypPrefix.isPrefixOf n

def getForwardHypTypes : MetaM (HashSet Expr) := do
  let mut result := {}
  for ldecl in (← getLCtx) do
    if ldecl.isImplementationDetail && isForwardHypName ldecl.userName then
      result := result.insert ldecl.type
  return result

def applyForwardRule (goal : MVarId) (e : Expr)
    (immediate : UnorderedArraySet Nat) (clear : Bool) : MetaM MVarId :=
  goal.withContext do
    let (newHypProofs, usedHyps) ←
      makeForwardHyps e immediate (collectUsedHyps := clear)
    if newHypProofs.isEmpty then
      err
    let forwardHypTypes ← getForwardHypTypes
    let mut newHyps := Array.mkEmpty newHypProofs.size
    let mut newHypTypes : HashSet Expr := {}
    for proof in newHypProofs do
      let type ← inferType proof
      if forwardHypTypes.contains type || newHypTypes.contains type then
        continue
      newHypTypes := newHypTypes.insert type
      newHyps := newHyps.push {
        userName := ← mkFreshForwardHypName
        value := proof
        type
      }
    if newHyps.isEmpty then
      err
    let (_, goal) ← goal.assertHypotheses newHyps
    let implDetailHyps ← newHyps.mapM λ hyp =>
      return {
        hyp with
        userName := ← mkFreshForwardHypName
        binderInfo := .default
        kind := .implDetail
      }
    let (_, goal) ← goal.assertHypotheses' implDetailHyps
    if clear then
      tryClearMany' goal usedHyps
    else
      return goal
  where
    err {α} : MetaM α := throwError
      "found no instances of {e} (other than possibly those which had been previously added by forward rules)"

@[inline]
def forwardExpr (e : Expr) (immediate : UnorderedArraySet Nat)
    (clear : Bool) : RuleTac :=
  SimpleRuleTac.toRuleTac λ input => input.goal.withContext do
    let goal ← applyForwardRule input.goal e immediate clear
    return [goal]

def forwardConst (decl : Name) (immediate : UnorderedArraySet Nat)
    (clear : Bool) : RuleTac := λ input => do
  forwardExpr (← mkConstWithFreshMVarLevels decl) immediate clear input

def forwardFVar (userName : Name) (immediate : UnorderedArraySet Nat)
    (clear : Bool) : RuleTac := λ input =>
  input.goal.withContext do
    let ldecl ← getLocalDeclFromUserName userName
    forwardExpr (mkFVar ldecl.fvarId) immediate clear input

end Aesop.RuleTac
