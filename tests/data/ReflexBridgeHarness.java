import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

import orsc.ReflexBridge;

/**
 * The fake host for tests/test_game_reflex_bridge.sh: drives the real
 * orsc.ReflexBridge (compiled read-only out of the local game checkout)
 * against a scripted player so the bridge<->engine file protocol of
 * specs/game-reflex.md is proven without a game, a display, or a login.
 *
 * Usage: ReflexBridgeHarness <state-dir> <mode>
 *   state      one tick, logged in  (writes the snapshot, executes pending)
 *   state-out  one tick, logged out
 *   exec       alias of state, named for the action-execution cases
 *   exec-out   alias of state-out
 *   fail5      seven ticks against a throwing host: the disable path
 *
 * Every host action the bridge executes is printed to stdout, one line each:
 * "eat slot=N", "walk x=N z=N", "shown <text>".
 */
public class ReflexBridgeHarness {

	static class FakeHost implements ReflexBridge.Host {
		boolean loggedIn = true;
		boolean failing = false;
		final List<String> events = new ArrayList<String>();
		final int[] invIds = {132, 81};
		final int[] invCounts = {1, 3};

		public boolean isLoggedIn() {
			if (failing) {
				throw new RuntimeException("scripted failure");
			}
			return loggedIn;
		}

		public int hits() {
			return 4;
		}

		public int hitsMax() {
			return 10;
		}

		public int fatigue() {
			return 12;
		}

		public int x() {
			return 120;
		}

		public int z() {
			return 650;
		}

		public boolean inCombat() {
			return false;
		}

		public boolean hasOpponent() {
			return false;
		}

		public int opponentX() {
			return 0;
		}

		public int opponentZ() {
			return 0;
		}

		public int inventorySize() {
			return invIds.length;
		}

		public int inventoryId(int slot) {
			return invIds[slot];
		}

		public int inventoryAmount(int slot) {
			return invCounts[slot];
		}

		public boolean isConsumable(int slot) {
			return invIds[slot] == 132;
		}

		public List<String> recentMessages(int max) {
			List<String> out = new ArrayList<String>();
			out.add("Welcome to the \"quoted\" world");
			return out;
		}

		// Two scripted visible NPCs: server index 7 is type 474 two tiles
		// away, server index 9 is type 485 five tiles away. Deliberately
		// listed FAR one first, so the snapshot's nearest-first sort is
		// observable, not an accident of input order.
		final int[] npcSidx = {9, 7};
		final int[] npcType = {485, 474};
		final int[] npcAbsX = {125, 121};
		final int[] npcAbsZ = {650, 651};

		public int npcCount() {
			return npcSidx.length;
		}

		public int npcServerIndex(int i) {
			return npcSidx[i];
		}

		public int npcTypeId(int i) {
			return npcType[i];
		}

		public int npcX(int i) {
			return npcAbsX[i];
		}

		public int npcZ(int i) {
			return npcAbsZ[i];
		}

		public void talkToNpc(int serverIndex) {
			events.add("talk sidx=" + serverIndex);
		}

		public void useItem(int slot) {
			events.add("eat slot=" + slot);
		}

		public void walkToTile(int absX, int absZ) {
			events.add("walk x=" + absX + " z=" + absZ);
		}

		public void showLocalMessage(String text) {
			events.add("shown " + text);
		}
	}

	public static void main(String[] args) {
		String dir = args[0];
		String mode = args[1];
		ReflexBridge bridge = new ReflexBridge(Paths.get(dir));
		FakeHost host = new FakeHost();
		if ("state-out".equals(mode) || "exec-out".equals(mode)) {
			host.loggedIn = false;
		}
		if ("fail5".equals(mode)) {
			host.failing = true;
			for (int i = 0; i < 7; i++) {
				bridge.tick(host);
			}
			System.out.println("disabled=" + bridge.isDisabled());
		} else {
			bridge.tick(host);
		}
		for (String event : host.events) {
			System.out.println(event);
		}
	}
}
