# Inventory preparation belongs to the activity

## Contract

1. Inventory preparation is an explicit decision for the current objective, activity, method,
   and sitting. Combat food, worn gear, and quest supplies do not become permanent possessions
   merely because an earlier task needed them. Memories inform a fresh decision; they do not
   exempt it. Re-evaluate actual risks, needed tools, materials/products, and batch capacity.
2. `play loadout enable` enables the preparation gate in the durable game store. A missing
   policy file keeps legacy stores compatible; an enabled store requires a matching inventory
   declaration before ordinary activity reflexes run. `play loadout` reports the assessment and
   discrepancies. `play loadout set FILE` validates and atomically saves a JSON declaration for
   the current context. The declaration is data, not a bridge action or a model call.
3. A declaration has `risk` (concrete activity/route hazards), `min_working_slots` (0..30), and
   `items`: unique `id`, `role` (`tool`, `support`, `food`, `material`, or `product`), `min`, `max`,
   and a nonempty `reason`. Counts are inventory quantities; occupied slots count each actual
   inventory entry, including worn items and one slot per stack. Working capacity is 30 minus
   occupied tool/support/food/undeclared slots: materials and products consume that capacity
   productively. A full batch is not itself a preparation fault.
   Plan for the complete work cycle, including expected sale proceeds and byproducts. An item
   absent from the declaration requires a purpose assessment: retain and classify it if useful,
   otherwise bank it. An unclassified item is not automatically junk or a reason for a bank trip.
4. Saving a declaration does not certify the inventory. Each runtime check compares fresh
   inventory against it: missing required tools, excess quantities, undeclared items, and
   insufficient working capacity return `no-rule-matched` with `inventory_prepare` and the
   required preparation door. Replacing the objective or method, changing productive activity,
   or beginning another sitting requires a fresh declaration. One current declaration is kept;
   there is no global food reserve or automatically inherited combat template.
5. The gate sits below stale/logged-out, movement, action-slot, healing, urgent retreat,
   conversation, and session checks. It does not abandon combat, an open interface, or an
   in-flight action. Banking, travel, trading/selling/shopping, recovery, and resupply modes remain usable to satisfy the
   declaration. The independent survival engine is unchanged. Direct semantic preparation
   actions remain available. A preparation detour preserves the competitive skill target.
   A missing or invalid declaration assessment itself names the supported recovery modes and
   explains that it holds routine route execution: inspect the catalog with `play activity
   --consider`, select an existing banking/travel/resupply operation, prepare, return to the
   productive operation and declare/verify its inventory. A preparation-sounding custom name
   does not bypass the gate. This guidance travels inside the assessment, so it remains visible
   even when a compact resident-runner verdict omits the outer next-action field.
   The ordinary deliberation verdict carries the current inventory assessment, including when
   the resident runner performed the check. The runner reloads when either inventory or decision
   module changes, so improvements by the reviewer take effect in an existing sitting.
6. The model must justify food and other non-working slots against current risks and observed
   consumption, deposit irrelevant/excess items, acquire required tools, and verify the resulting
   inventory before resuming. A vague inherited safety reserve or an old plan's item list is
   insufficient evidence. It may keep food when the actual activity or route warrants it; it may
   keep none when it does not. The periodic reviewer sees the declaration and live inventory,
   audits the reasoning and actual batch capacity, and repairs recurring pickup/banking rules
   that recreate an unsuitable inventory. Inventory details belong in the activity declaration;
   the objective and training plan retain their actual goal and method.

7. A ready declaration also constrains ordinary automatic ground pickups, before dispatch:
   an undeclared item or one already at its declared maximum cannot be acquired merely because
   an old global loot rule is enabled. Check again at emission against fresh state. This applies
   in the declared productive activity and its travelling/travel/transit/walking/journey and trading/selling/shopping modes
   when objective, plan, and sitting still match; explicit banking/resupply/recovery preparation
   stays usable. A missing or stale declaration in productive activity fails closed; travel
   without a matching productive declaration retains legacy behaviour. This filter never affects
   eating, retreat, item use on ground, or deliberate preparation doors. Pure learned-rule replays
   remain independent of the live loadout; isolated integration cases test this runtime policy.
   The refusal names the inventory policy rather than teaching the rule an invented failure.

## Decisions persist until fulfilled or deliberately revised

Record a chosen course when making it, before promising it in chat. `play decision set FILE`
stores a JSON decision with `key`, `choice`, `reason`, `trigger`, `items` (item ids, empty for a
non-inventory decision), and `disposition` (`sell`, `bank`, `use`, `keep`, or `drop`).
`play reply ID --decision FILE "TEXT"` stores the decision before sending the reply. This is an
explicit commitment supplied by the player, not an automatic interpretation of natural language.
The ordinary plan must agree with these decisions. A full bag activates the chosen batch disposal
method; it does not choose a new one. No quantity of old memories substitutes for recording the
current choice.

Decisions survive activity changes, plan changes, process restarts, and sitting boundaries. They
do not become universal inventory rules: they name a particular course and its item identities.
Changing an active decision requires `--revise "OBSERVED REASON"`; ending one requires
`play decision close KEY --reason "VERIFIED RESULT OR REASON"`. The atomic, locked store retains
the previous values and explanations. Conflicting active decisions for the same item are refused.
New evidence, an explicit user redirect, or a deliberate, explained tradeoff can justify a change.
An ordinary full inventory, proximity to a bank, or forgetting the choice does not.
The commitment is its intended outcome and constraints. An incidental route or previously known
shop is not binding unless the user specifically required it. Prefer inspecting suitable local
facilities to making repeated distant trips. Verification establishes suitability; it is not a
requirement to use only a previously visited facility. Judge efficiency across the complete cycle
of supplies, production, disposal, and return, including unnecessary retained inventory.

With inventory preparation enabled, each declared product needs an active disposal decision.
The direct bank-deposit, shop-sell, and drop doors refuse an action that contradicts a recorded
item disposition. They print the decision and its reason so the player can follow it or explicitly
revise it. The guard also checks legacy bank/shop inventory selection; use the semantic transaction
door to disambiguate a withdrawal or other permitted operation. Emergency healing and retreat are
unaffected. The periodic review compares conversation evidence, decisions, and completed actions;
it checks that a revision has a substantive reason, rather than accepting a reason field alone.

## Example declaration

```json
{
  "risk": "Production beside the bank, no observed hostile NPCs on this route",
  "min_working_slots": 27,
  "items": [
    {"id": 13, "role": "tool", "min": 1, "max": 1, "reason": "Cut logs"},
    {"id": 14, "role": "material", "min": 0, "max": 29, "reason": "Current batch"},
    {"id": 276, "role": "product", "min": 0, "max": 29, "reason": "Output for the chosen disposal method"}
  ]
}
```

The example is a format example, not a universal recipe. Choose item identities and capacity
from the actual method, inventory, and live risks.
