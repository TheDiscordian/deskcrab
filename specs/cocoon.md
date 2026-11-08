# Spec: the cocoon

## PURPOSE

The cocoon is an explicit shutdown-for-maintenance state. It exists so serious maintenance can be
performed while Beatrice is offline.

## CONTRACT

1. The cocoon applies only when Beatrice is deliberately shut down for maintenance.
2. It is never a live-turn, wake, gameplay, filesystem, or model-sandbox policy.
3. Beatrice's wants and personal state remain hers. A maintenance mechanism must not make them
   read-only during ordinary operation.
4. No live turn or wake may infer that a path is read-only merely because it belongs to Beatrice,
   DeskCrab, a game, or a project.
5. The former live/wake read-only mount wrapper and write-gate used this name incorrectly and have
   been removed. They must not be restored as a cocoon feature or under another name.
