/-
Copyright (c) 2022 Jannis Limperg. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jannis Limperg
-/

import Aesop.RuleTac
import Aesop.Search.Expansion.Simp
import Aesop.Search.RuleSelection

open Lean
open Lean.Meta

namespace Aesop

variable [Aesop.Queue Q]

inductive RuleResult
  | proven
  | failed
  | succeeded
  | postponed (result : PostponedSafeRule)

def RuleResult.isSuccessful
  | proven => true
  | succeeded => true
  | failed => false
  | postponed .. => false


inductive NormRuleResult
  | succeeded (goal : MVarId) (branchState : BranchState)
  | proven
  | failed

def runRuleTac (tac : RuleTac) (ruleName : RuleName)
    (preState : Meta.SavedState) (input : RuleTacInput) :
    MetaM (Sum Exception RuleTacOutput) := do
  let result ←
    try
      Sum.inr <$> preState.runMetaM' (tac input)
    catch e =>
      return Sum.inl e
  if ← Check.rules.isEnabled then
    if let (Sum.inr ruleOutput) := result then
      ruleOutput.applications.forM λ rapp => do
        if let (some err) ← rapp.check then
          throwError "{Check.rules.name}: while applying rule {ruleName}: {err}"
  return result

def runRegularRuleTac (goal : Goal) (tac : RuleTac) (ruleName : RuleName)
    (indexMatchLocations : UnorderedArraySet IndexMatchLocation)
    (branchState : RuleBranchState) :
    MetaM (Sum Exception RuleTacOutput) := do
  let some (postNormGoal, postNormState) := goal.postNormGoalAndMetaState? | throwError
    "aesop: internal error: expected goal {goal.id} to be normalised (but not proven by normalisation)."
  let input := {
    goal := postNormGoal
    mvars := goal.mvars
    indexMatchLocations, branchState
  }
  runRuleTac tac ruleName postNormState input

-- NOTE: Must be run in the MetaM context of the relevant goal.
def runNormRuleTac (bs : BranchState) (rule : NormRule) (input : RuleTacInput) :
    MetaM NormRuleResult := do
  let preMetaState ← saveState
  let result? ← runRuleTac rule.tac.run rule.name preMetaState input
  match result? with
  | Sum.inl e =>
    aesop_trace[stepsNormalization] "Rule failed with error:{indentD e.toMessageData}"
    return .failed
  | Sum.inr result =>
    let #[rapp] := result.applications
      | err m!"rule did not produce exactly one rule application."
    restoreState rapp.postState
    if rapp.goals.isEmpty then
      aesop_trace[stepsNormalization] "Rule proved the goal."
      return .proven
    let (#[g]) := rapp.goals
      | err m!"rule produced more than one subgoal."
    let postBranchState := bs.update rule result.postBranchState?
    aesop_trace[stepsNormalization] do
      aesop_trace![stepsNormalization] "Rule succeeded. New goal:{indentD $ .ofGoal g}"
      aesop_trace[stepsBranchStates] "Branch state after rule application: {postBranchState.find? rule}"
    return .succeeded g postBranchState
  where
    err {α} (msg : MessageData) : MetaM α := throwError
      "aesop: error while running norm rule {rule.name}: {msg}\nThe rule was run on this goal:{indentD $ MessageData.ofGoal input.goal}"

-- NOTE: Must be run in the MetaM context of the relevant goal.
def runNormRuleCore (goal : MVarId) (mvars : UnorderedArraySet MVarId)
    (bs : BranchState) (rule : IndexMatchResult NormRule) :
    MetaM NormRuleResult := do
  let branchState := bs.find rule.rule
  aesop_trace[stepsNormalization] do
    aesop_trace![stepsNormalization] "Running {rule.rule}"
    aesop_trace[stepsBranchStates] "Branch state before rule application: {branchState}"
  let ruleInput := {
    indexMatchLocations := rule.locations
    goal, mvars, branchState
  }
  runNormRuleTac bs rule.rule ruleInput

-- NOTE: Must be run in the MetaM context of the relevant goal.
def runNormRule (goal : MVarId) (mvars : UnorderedArraySet MVarId)
    (bs : BranchState) (rule : IndexMatchResult NormRule) :
    ProfileT MetaM NormRuleResult :=
  profiling (runNormRuleCore goal mvars bs rule) λ result elapsed => do
    let successful :=
      match result with
      | .proven => true
      | .succeeded .. => true
      | .failed .. => false
    let rule := RuleProfileName.rule rule.rule.name
    let ruleProfile := { elapsed, successful, rule }
    recordAndTraceRuleProfile ruleProfile

-- NOTE: Must be run in the MetaM context of the relevant goal.
def runFirstNormRule (goal : MVarId) (mvars : UnorderedArraySet MVarId)
    (branchState : BranchState) (rules : Array (IndexMatchResult NormRule)):
    ProfileT MetaM NormRuleResult := do
  for rule in rules do
    let result ← runNormRule goal mvars branchState rule
    match result with
    | .proven => return result
    | .failed => continue
    | .succeeded _ _ => return result
  return .failed

def normSimpCore (useHyps : Bool) (ctx : Simp.Context)
    (localSimpRules : Array LocalNormSimpRule) (goal : MVarId)
    (mvars : UnorderedArraySet MVarId) : MetaM SimpResult := do
  goal.withContext do
    let lctx ← getLCtx
    let mut simpTheorems := ctx.simpTheorems
    for localRule in localSimpRules do
      let (some ldecl) := lctx.findFromUserName? localRule.fvarUserName
        | continue
      let origin := Origin.fvar ldecl.fvarId
      let (some simpTheorems') ← observing? $
        simpTheorems.addTheorem origin ldecl.toExpr
        | continue
      simpTheorems := simpTheorems'
    let ctx := { ctx with simpTheorems }

    let (result, _) ←
      if useHyps then
        Aesop.simpAll goal ctx (disabledTheorems := {})
      else
        let mut fvarIdsToSimp := Array.mkEmpty lctx.decls.size
        for ldecl in lctx do
          -- TODO exclude non-prop and dependent hyps?
          if ldecl.isImplementationDetail then
            continue
          fvarIdsToSimp := fvarIdsToSimp.push ldecl.fvarId
        Aesop.simpGoal goal ctx (fvarIdsToSimp := fvarIdsToSimp)
          (disabledTheorems := {})

    -- It can happen that simp 'solves' the goal but leaves some mvars
    -- unassigned. In this case, we treat the goal as unchanged.
    if let .solved := result then
      let anyMVarDropped ← mvars.anyM λ mvarId =>
        return ! (← mvarId.isAssigned) &&
                ! (← mvarId.isDelayedAssigned)
      if anyMVarDropped then
        aesop_trace[stepsNormalization] "Normalisation simp solved the goal but dropped some metavariables. Skipping normalisation simp."
        return .unchanged goal
      else
        return result
    return result

-- NOTE: Must be run in the MetaM context of the relevant goal.
def normSimp (goal : MVarId) (mvars : UnorderedArraySet MVarId) (useHyps : Bool)
    (ctx : Simp.Context) (localSimpRules : Array LocalNormSimpRule) :
    ProfileT MetaM SimpResult :=
  profiling go λ _ elapsed =>
    recordAndTraceRuleProfile { rule := .normSimp, elapsed, successful := true }
  where
    go : MetaM SimpResult := do
      if ← Check.rules.isEnabled then
        let preMetaState ← saveState
        let result ← normSimpCore useHyps ctx localSimpRules goal mvars
        let postMetaState ← saveState
        let introduced :=
          (← introducedExprMVars preMetaState postMetaState).filter
            (some · != result.newGoal?)
        unless introduced.isEmpty do throwError
          "{Check.rules.name}: norm simp introduced metas:{introduced.map (·.name)}"
        let assigned :=
          (← assignedExprMVars preMetaState postMetaState).filter (· != goal)
        unless assigned.isEmpty do throwError
          "{Check.rules.name}: norm simp assigned metas:{introduced.map (·.name)}"
        return result
      else
        normSimpCore useHyps ctx localSimpRules goal mvars

-- NOTE: Must be run in the MetaM context of the relevant goal.
partial def normalizeGoalMVar (rs : RuleSet) (normSimpUseHyps : Bool)
    (ctx : Simp.Context) (maxIterations : Nat) (goal : MVarId)
    (mvars : UnorderedArraySet MVarId) (bs : BranchState) :
    ProfileT MetaM (Option (MVarId × BranchState)) :=
  go 0 goal bs
  where
    go (iteration : Nat) (goal : MVarId) (bs : BranchState) :
        ProfileT MetaM (Option (MVarId × BranchState)) := do
      if maxIterations > 0 && iteration > maxIterations then throwError
        "aesop: exceeded maximum number of normalisation iterations ({maxIterations}). This means normalisation probably got stuck in an infinite loop."
      let rules ← selectNormRules rs goal
      let (preSimpRules, postSimpRules) :=
        rules.partition λ r => r.rule.extra.penalty < (0 : Int)
      let preSimpResult ← runFirstNormRule goal mvars bs preSimpRules
      match preSimpResult with
      | .proven => return none
      | .succeeded goal bs => go (iteration + 1) goal bs
      | .failed =>
        aesop_trace[stepsNormalization] "Running normalisation simp"
        let simpResult ←
          normSimp goal mvars normSimpUseHyps ctx rs.localNormSimpLemmas
        match simpResult with
        | .solved => return none
        | .simplified goal =>
          aesop_trace[stepsNormalization] "Goal after normalisation simp:{indentD $ MessageData.ofGoal goal}"
          go (iteration + 1) goal bs
        | .unchanged goal =>
          aesop_trace[stepsNormalization] "Goal unchanged after normalisation simp."
          let postSimpResult ← runFirstNormRule goal mvars bs postSimpRules
          match postSimpResult with
          | .proven => return none
          | .succeeded goal bs => go (iteration + 1) goal bs
          | .failed => return some (goal, bs)

-- Returns true if the goal was solved by normalisation.
def normalizeGoalIfNecessary (gref : GoalRef) : SearchM Q Bool := do
  let g ← gref.get
  match g.normalizationState with
  | .provenByNormalization .. => return true
  | .normal .. => return false
  | .notNormal => pure ()
  aesop_trace[steps] "Normalising the goal"
  let ctx ← read
  let profilingEnabled ← isProfilingEnabled
  let profile ← getThe Profile
  let ((postGoal?, profile), postState) ←
    (← gref.get).runMetaMInParentState do
      aesop_trace[steps] "Goal before normalisation:{indentD $ MessageData.ofGoal g.preNormGoal}"
      let (postGoal?, profile) ←
        normalizeGoalMVar ctx.ruleSet ctx.normSimpUseHyps ctx.normSimpContext
          ctx.options.maxNormIterations g.preNormGoal g.mvars g.branchState
        |>.run profilingEnabled profile
      if let (some (postGoal, _)) := postGoal? then
        aesop_trace[steps] "Goal after normalisation ({postGoal.name}):{indentD $ toMessageData postGoal}"
        -- This trace needs to happen within the `runMetaMInParentState` to make
        -- sure that the goal is printed correctly.
      return (postGoal?, profile)
  modify λ s => { s with profile }
  match postGoal? with
  | some (postGoal, postBranchState) =>
    gref.modify λ g =>
      g.setNormalizationState (NormalizationState.normal postGoal postState)
      |>.setBranchState postBranchState
    return false
  | none =>
    aesop_trace[steps] "Normalisation solved the goal"
    gref.modify λ g =>
      g.setNormalizationState (NormalizationState.provenByNormalization postState)
    gref.markProvenByNormalization
    return true

def addRapps (parentRef : GoalRef) (rule : RegularRule)
    (rapps : Array RuleApplicationWithMVarInfo)
    (postBranchState? : Option RuleBranchState) : SearchM Q RuleResult := do
  let parent ← parentRef.get
  let postBranchState :=
    rule.withRule λ r => parent.branchState.update r postBranchState?
  aesop_trace[stepsBranchStates] "Updated branch state: {rule.withRule λ r => postBranchState.find? r}"
  let successProbability := parent.successProbability * rule.successProbability

  let mut rrefs := Array.mkEmpty rapps.size
  let mut subgoals := Array.mkEmpty $ rapps.size * 3
  for h : i in [:rapps.size] do
    let rapp := rapps[i]'(by simp_all [Membership.mem])
    let rref ← addRapp {
      rapp with
      parent := parentRef
      appliedRule := rule
      branchState := postBranchState
      successProbability }
    rrefs := rrefs.push rref
    for cref in (← rref.get).children do
      for gref in (← cref.get).goals do
        subgoals := subgoals.push gref

  enqueueGoals subgoals
  rrefs.forM (·.markProven)
    -- `markProven` is a no-op if the rapp is not, in fact, proven. We must
    -- perform this computation after all rapps have been added to ensure
    -- that if one is proven, the others are all marked as irrelevant.

  aesop_trace[steps] do
    let traceMods ← TraceModifiers.get
    let rappMsgs ← rrefs.mapM λ rref => do
      let r ← rref.get
      let rappMsg ← r.toMessageData
      let subgoalMsgs ← r.foldSubgoalsM (init := #[]) λ msgs gref =>
        return msgs.push (← (← gref.get).toMessageData traceMods)
      return rappMsg ++ MessageData.node subgoalMsgs
    aesop_trace![steps] "New rapps and goals:{MessageData.node rappMsgs}"

  let provenRref? ← rrefs.findM? λ rref => return (← rref.get).state.isProven
  if let (some _) := provenRref? then
    aesop_trace[steps] "One of the rule applications has no subgoals. Goal is proven."
    return RuleResult.proven
  else
    return RuleResult.succeeded

def runRegularRuleCore (parentRef : GoalRef) (rule : RegularRule)
    (indexMatchLocations : UnorderedArraySet IndexMatchLocation) :
    SearchM Q RuleResult := do
  let parent ← parentRef.get
  let initialBranchState := rule.withRule λ r => parent.branchState.find r
  aesop_trace[stepsBranchStates] "Initial branch state: {initialBranchState}"
  let ruleOutput? ←
    runRegularRuleTac parent rule.tac.run rule.name indexMatchLocations
      initialBranchState
  match ruleOutput? with
  | Sum.inl exc => onFailure exc.toMessageData
  | Sum.inr { applications := #[], .. } =>
    onFailure "Rule returned no rule applications."
  | Sum.inr output =>
    let rapps ← output.applications.mapM
      (·.toRuleApplicationWithMVarInfo parent.mvars)
    if let (.safe rule) := rule then
      if rapps.size != 1 then
        return ← onFailure "Safe rule did not produce exactly one rule application. Treating it as failed."
      if rapps.any (! ·.assignedMVars.isEmpty) then
        aesop_trace[steps] "Safe rule assigned metavariables. Postponing it."
        return RuleResult.postponed ⟨rule, output⟩
    aesop_trace[steps] "Rule succeeded, producing {rapps.size} rule application(s)."
    addRapps parentRef rule rapps output.postBranchState?
  where
    onFailure (msg : MessageData) : SearchM Q RuleResult := do
      aesop_trace[stepsRuleFailures] "Rule failed with message:{indentD msg}"
      parentRef.modify λ g => g.setFailedRapps $ g.failedRapps.push rule
      return RuleResult.failed

def runRegularRule (parentRef : GoalRef) (rule : RegularRule)
    (indexMatchLocations : UnorderedArraySet IndexMatchLocation) :
    SearchM Q RuleResult :=
  profiling (runRegularRuleCore parentRef rule indexMatchLocations)
    λ result elapsed => do
      let successful :=
        match result with
        | .failed => false
        | .succeeded => true
        | .proven => true
        | .postponed .. => true
      let rule := RuleProfileName.rule rule.name
      recordAndTraceRuleProfile { rule, elapsed, successful }

-- Never returns `RuleResult.postponed`.
def runFirstSafeRule (gref : GoalRef) :
    SearchM Q (RuleResult × Array PostponedSafeRule) := do
  let g ← gref.get
  if g.unsafeRulesSelected then
    return (RuleResult.failed, #[])
    -- If the unsafe rules have been selected, we have already tried all the
    -- safe rules.
  let rules ← selectSafeRules g
  aesop_trace[steps] "Selected safe rules:{MessageData.node $ rules.map toMessageData}"
  aesop_trace[steps] "Trying safe rules"
  let mut postponedRules := {}
  for r in rules do
    aesop_trace[steps] "Trying {r.rule}"
    let result' ←
      runRegularRule gref (.safe r.rule) r.locations
    match result' with
    | .failed => continue
    | .proven => return (result', #[])
    | .succeeded => return (result', #[])
    | .postponed r =>
      postponedRules := postponedRules.push r
  return (RuleResult.failed, postponedRules)

partial def runFirstUnsafeRule (postponedSafeRules : Array PostponedSafeRule)
    (parentRef : GoalRef) : SearchM Q Unit := do
  let queue ← selectUnsafeRules postponedSafeRules parentRef
  aesop_trace[steps] "Trying unsafe rules"
  let (remainingQueue, _) ← loop queue
  parentRef.modify λ g => g.setUnsafeQueue remainingQueue
  aesop_trace[steps] "Remaining unsafe rules:{MessageData.node remainingQueue.entriesToMessageData}"
  if remainingQueue.isEmpty then
    if (← parentRef.get).state.isProven then
      return
    if ← (← parentRef.get).isUnprovableNoCache then
      aesop_trace[steps] "Goal is unprovable."
      parentRef.markUnprovable
    else
      aesop_trace[steps] "All rules applied, goal is exhausted."
  where
    loop (queue : UnsafeQueue) : SearchM Q (UnsafeQueue × RuleResult) := do
      let (some (r, queue)) := queue.popFront?
        | return (queue, RuleResult.failed)
      match r with
      | .unsafeRule r =>
        aesop_trace[steps] "Trying {r.rule}"
        let result ←
          runRegularRule parentRef (.«unsafe» r.rule) r.locations
        match result with
        | .proven => return (queue, result)
        | .succeeded => return (queue, result)
        | .postponed .. => throwError
          "aesop: internal error: applying an unsafe rule yielded a postponed safe rule."
        | .failed => loop queue
      | .postponedSafeRule r =>
        aesop_trace[steps] "Applying postponed safe rule {r.rule}"
        let parentMVars := (← parentRef.get).mvars
        let postBranchState? := r.output.postBranchState?
        let rapps ← r.output.applications.mapM
          (·.toRuleApplicationWithMVarInfo parentMVars)
        let result ←
          addRapps parentRef (.«unsafe» r.toUnsafeRule) rapps postBranchState?
        return (queue, result)

def expandGoal (gref : GoalRef) : SearchM Q Unit := do
  if ← normalizeGoalIfNecessary gref then
    -- Goal was already proven by normalisation.
    return
  let (safeResult, postponedSafeRules) ← runFirstSafeRule gref
  unless safeResult.isSuccessful do
    runFirstUnsafeRule postponedSafeRules gref

end Aesop
