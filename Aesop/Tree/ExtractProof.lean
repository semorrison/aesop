/-
Copyright (c) 2022 Jannis Limperg. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jannis Limperg
-/

import Aesop.Tracing
import Aesop.Tree.Format
import Aesop.Tree.TreeM

open Lean
open Lean.Meta

/-
To extract a proof, we start in the `MetaM` state in which Aesop was called.
Then we iterate through the proven part of the tree, top to bottom, 'replaying'
the mvar assignments that were performed during the search. This means:

- For each goal `g`, we assign `g`'s pre-norm mvar to the term generated by
  normalisation. If `g` was proved by normalisation, we are done. Otherwise,
  we find the proving child rapp of `g` and descend into it.
- For each rapp `r`, we assign the post-norm mvar of `r`'s parent goal to the
  term generated by `r`. Additionally, we assign each mvar assigned by `r`.
  Then we descend into `r`'s children.
- For each mvar cluster `c`, we find the proven goal of `c` and descend into it.

When we assign a metavariable `m`, we must take some care:

- We must first declare `m` if it is not already declared.
- We must assign (and declare) any metavariables on which the assignment of `m`
  depends. We cannot assume that these assignments are meta-free, since they may
  contain metavariables that were only assigned later during the search. We
  also cannot assume that these are the *only* metavariables occurring in the
  assignments, since they may additionally contain delayed-assigned
  metavariables which depend on the unassigned metavariables.

We also replay env modifications in a similar fashion. We assume that rules only
add declarations to the environment.

If the root goal is not proven, we extract the goals after safe rule
applications. This means we proceed as above, but stop as soon as we reach the
first non-safe rule application. If a goal has multiple safe rule applications,
we arbitrarily choose the first one. (This should happen rarely in practice.)
-/

namespace Aesop

local macro "throwPRError " s:interpolatedStr(term) : term =>
  `(throwError m!"aesop: internal error during proof reconstruction: " ++ m!$s)


-- ## Copying Declarations

private def getNewConsts (oldEnv newEnv : Environment) :
    Array ConstantInfo := Id.run do
  let oldMap₂ := oldEnv.constants.map₂
  let newMap₂ := newEnv.constants.map₂
  if oldMap₂.size == newMap₂.size then
    #[]
  else
    newMap₂.foldl (init := #[]) λ cs n c =>
      if oldMap₂.contains n then cs else cs.push c

-- For each declaration `d` that appears in `newState` but not in
-- `oldState`, add `d` to the environment. We assume that the environment in
-- `newState` is a local extension of the environment in `oldState`, meaning
--
-- 1. The declarations in `newState` are a superset of the declarations in
--    `oldState`.
-- 2. The `map₁`s of the environments in `newState` and `oldState` are
--    identical. (These contain imported decls.)
private def copyNewDeclarations (oldEnv newEnv : Environment) : CoreM Unit := do
  let newConsts := getNewConsts oldEnv newEnv
  setEnv $ newConsts.foldl (init := ← getEnv) λ env c => env.add c

open Match in
private def copyMatchEqnsExtState (oldEnv newEnv : Environment) : CoreM Unit := do
  let oldState := matchEqnsExt.getState oldEnv
  let newState := matchEqnsExt.getState newEnv
  if newState.map.size > oldState.map.size then
    for (n, eqns) in newState.map do
      if !oldState.map.contains n then
        registerMatchEqns n eqns

-- ## Copying Metavariables

private partial def copyExprMVar (s : Meta.SavedState) (mvarId : MVarId) :
    MetaM Unit := do
  if ← mvarId.isAssigned <||> mvarId.isDelayedAssigned then
    return
  unless ← isExprMVarDeclared mvarId do
    let decl ← s.runMetaM' $ do
      instantiateMVarsInGoal mvarId
      let decl ← mvarId.getDecl
      aesop_trace[extraction] "declare ?{mvarId.name}:{indentD $ toMessageData mvarId}"
      pure decl
    modifyMCtx λ mctx => { mctx with decls := mctx.decls.insert mvarId decl }
    let depMVarIds ← getGoalMVarDependencies mvarId (includeDelayed := true)
    for depMVarId in depMVarIds do
      copyExprMVar s depMVarId
  let assignment? ← s.runMetaM' do
    if let (some e) ← getExprMVarAssignment? mvarId then
      return some $ Sum.inl $ ← instantiateMVars e
    else if let (some d) ← getDelayedMVarAssignment? mvarId then
      return some $ Sum.inr d
    else
      return none
  match assignment? with
  | some (Sum.inl e) =>
    for mvarId in ← getMVars e do
      copyExprMVar s mvarId
    aesop_trace[extraction] "assign  ?{mvarId.name} := {toString e}"
    mvarId.assign e
  | some (Sum.inr d) =>
    for mvarId in ← getMVars (mkMVar d.mvarIdPending) do
      copyExprMVar s mvarId
    aesop_trace[extraction] "dassign ?{mvarId.name} := {d.fvars} => {d.mvarIdPending.name}"
    delayedAssignMVar mvarId d
  | none => return

-- ## Main Functions

private def visitGoal (g : Goal) : MetaM (Option (MVarId × Array RappRef)) := do
  aesop_trace[extraction] "visiting {← g.toMessageData (← TraceModifiers.get)}"
  match g.normalizationState with
  | NormalizationState.notNormal => throwPRError
    "goal {g.id} was not normalised."
  | NormalizationState.normal postNormGoal postState =>
    copyExprMVar postState g.preNormGoal
    return (postNormGoal, g.children)
  | NormalizationState.provenByNormalization postState =>
    copyExprMVar postState g.preNormGoal
    return none

private def visitRapp (parentEnv : Environment) (parentGoal : MVarId) (r : Rapp) :
    MetaM (Array MVarClusterRef × Environment) := do
  aesop_trace[extraction] "visiting {← r.toMessageData}"
  let newEnv := r.metaState.core.env
  copyNewDeclarations parentEnv newEnv
  copyMatchEqnsExtState parentEnv newEnv
  copyExprMVar r.metaState parentGoal
  for m in r.assignedMVars do
    copyExprMVar r.metaState m
  return (r.children, newEnv)

mutual
  private partial def extractProofGoal (parentEnv : Environment) (g : Goal) :
      MetaM Unit := do
    let (some (postNormGoal, children)) ← visitGoal g
      | return
    let rref? ← children.findM? λ rref => return (← rref.get).state.isProven
    let (some rref) := rref? | throwPRError
      "goal {g.id} does not have a proven rapp."
    extractProofRapp parentEnv postNormGoal (← rref.get)

  private partial def extractProofRapp (parentEnv : Environment)
      (parentGoal : MVarId) (r : Rapp) : MetaM Unit := do
    let (children, newEnv) ← visitRapp parentEnv parentGoal r
    children.forM λ cref => do extractProofMVarCluster newEnv (← cref.get)

  private partial def extractProofMVarCluster (parentEnv : Environment)
      (c : MVarCluster) : MetaM Unit := do
    let gref? ← c.goals.findM? λ gref => return (← gref.get).state.isProven
    let (some gref) := gref? | throwPRError
      "an mvar cluster does not contain a proven goal (candidate goals: {← c.goals.mapM λ gref => return (← gref.get).id})."
    extractProofGoal parentEnv (← gref.get)
end

private structure SafePrefixState where
  goals : Array MVarId := #[]

private abbrev SafePrefixM := StateRefT SafePrefixState MetaM

mutual
  private partial def extractSafePrefixGoal (parentEnv : Environment)
      (g : Goal) : SafePrefixM Unit := do
    let (some (postNormGoal, _)) ← visitGoal g
      | return
    let safeRapps ← g.safeRapps
    if safeRapps.size > 1 then
      throwError "aesop: internal error: goal {g.id} has multiple safe rapps"
    if h : 0 < safeRapps.size then
      extractSafePrefixRapp parentEnv postNormGoal (← safeRapps[0].get)
    else
      modify λ s => { s with goals := s.goals.push postNormGoal }

  private partial def extractSafePrefixRapp (parentEnv : Environment)
      (parentGoal : MVarId) (r : Rapp) : SafePrefixM Unit := do
    let (children, newEnv) ← visitRapp parentEnv parentGoal r
    children.forM λ cref => do extractSafePrefixMVarCluster newEnv (← cref.get)

  private partial def extractSafePrefixMVarCluster (parentEnv : Environment)
      (c : MVarCluster) : SafePrefixM Unit :=
    c.goals.forM λ gref => do extractSafePrefixGoal parentEnv (← gref.get)
end

def Goal.extractProof (root : Goal) : MetaM Unit := do
  extractProofGoal (← getEnv) root

def extractProof : TreeM Unit := do
  (← (← getRootGoal).get).extractProof

def Goal.extractSafePrefix (root : Goal) : MetaM (Array MVarId) := do
  let (_, state) ← extractSafePrefixGoal (← getEnv) root |>.run {}
  return state.goals

def extractSafePrefix : TreeM (Array MVarId) := do
  (← (← getRootGoal).get).extractSafePrefix

end Aesop
