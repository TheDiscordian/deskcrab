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
 * Usage: ReflexBridgeHarness <state-dir> <mode> [ticks]
 *   state      logged in  (writes the snapshot, executes pending)
 *   state-out  logged out
 *   exec       alias of state, named for the action-execution cases
 *   exec-offscreen logged in, but entity projections are unavailable
 *   exec-out   alias of state-out
 *   hurt       logged in at 3/10 hits: the flee-starved band
 *   fail5      seven ticks against a throwing host: the disable path
 * [ticks] runs that many bridge ticks (default 1), so a later snapshot write
 * (every 12th tick) gives the engine a genuinely new tick to act on.
 *
 * Every host action the bridge executes is printed to stdout, one line each:
 * "eat slot=N", "walk x=N z=N", "shown <text>", "talk sidx=N",
 * "object x=N z=N id=N cmd=N", "bound x=N z=N dir=N cmd=N",
 * "click x=N y=N button=N", "take x=N z=N id=N".
 */
public class ReflexBridgeHarness {

	static class FakeHost implements ReflexBridge.Host {
		boolean loggedIn = true;
		boolean failing = false;
		boolean projectionsVisible = true;
		boolean routeAvailable = true;
		boolean walking = false;
		boolean inCombat = false;
		boolean npcDialogueOpen = false;
		boolean shopOpen = true;
		boolean bankOpen = true;
		int hitsNow = 4;
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
			return hitsNow;
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

		public boolean isWalking() {
			return walking;
		}

		public boolean inCombat() {
			return inCombat;
		}

		public boolean isNpcDialogueOpen() {
			return npcDialogueOpen;
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

		public int[] inventoryScreenPoint(int slot) {
			return projectionsVisible ? new int[]{610 + slot, 310 + slot} : null;
		}

		public boolean isConsumable(int slot) {
			return invIds[slot] == 132;
		}

		final int[] shopIds = {10, 42, -1};
		final int[] shopCounts = {50, 3, 0};

		public boolean isShopOpen() {
			return shopOpen;
		}

		public int shopSlotCount() {
			return shopIds.length;
		}

		public int shopItemId(int slot) {
			return shopIds[slot];
		}

		public int shopItemAmount(int slot) {
			return shopCounts[slot];
		}

		public boolean shopItemNoted(int slot) {
			return slot == 1;
		}

		public String shopItemName(int slot) {
			return slot == 0 ? "Coins" : "Test \"parcel\"";
		}

		public int[] shopItemScreenPoint(int itemId) {
			for (int slot = 0; slot < shopIds.length; slot++) {
				if (shopIds[slot] == itemId) {
					return projectionsVisible ? new int[]{710 + slot, 410 + slot} : null;
				}
			}
			return null;
		}

		final int[] bankIds = {81, 145};
		final int[] bankCounts = {12, 1};

		public boolean isBankOpen() {
			return bankOpen;
		}

		public int bankItemCount() {
			return bankIds.length;
		}

		public int bankItemId(int slot) {
			return bankIds[slot];
		}

		public int bankItemAmount(int slot) {
			return bankCounts[slot];
		}

		public String bankItemName(int slot) {
			return slot == 0 ? "Lobster" : "Bucket";
		}

		public int[] bankItemScreenPoint(int itemId) {
			for (int slot = 0; slot < bankIds.length; slot++) {
				if (bankIds[slot] == itemId) {
					return projectionsVisible ? new int[]{810 + slot, 510 + slot} : null;
				}
			}
			return null;
		}

		final int[] playerSidx = {22, 0, 11};
		final String[] playerNames = {"Distant Player", "Beatrice", "Nearby Friend"};
		final int[] playerAbsX = {130, 120, 121};
		final int[] playerAbsZ = {660, 650, 650};

		public int localPlayerServerIndex() {
			return 0;
		}

		public int playerCount() {
			return playerSidx.length;
		}

		public int playerServerIndex(int i) {
			return playerSidx[i];
		}

		public String playerName(int i) {
			return playerNames[i];
		}

		public int playerX(int i) {
			return playerAbsX[i];
		}

		public int playerZ(int i) {
			return playerAbsZ[i];
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

		public int[] npcScreenPoint(int i) {
			return projectionsVisible ? new int[]{410 + i, 210 + i} : null;
		}

		public void talkToNpc(int serverIndex) {
			events.add("talk sidx=" + serverIndex);
		}

		// Two scripted loaded game objects: a gate (57) two tiles away, a
		// fishing spot (493) far to the south-east. FAR one listed first, so
		// the snapshot's nearest-first sort is observable.
		final int[] objId = {493, 57};
		final int[] objAbsX = {196, 121};
		final int[] objAbsZ = {726, 649};
		final int[] objDir = {0, 2};

		public int objectCount() {
			return objId.length;
		}

		public int objectId(int i) {
			return objId[i];
		}

		public int objectX(int i) {
			return objAbsX[i];
		}

		public int objectZ(int i) {
			return objAbsZ[i];
		}

		public int objectDir(int i) {
			return objDir[i];
		}

		public int[] objectScreenPoint(int i) {
			return projectionsVisible ? new int[]{310 + i, 160 + i} : null;
		}

		public void interactObject(int i, int command) {
			events.add("object x=" + objAbsX[i] + " z=" + objAbsZ[i]
					+ " id=" + objId[i] + " cmd=" + command);
		}

		// Two scripted wall objects: a door (1) on the north wall of the tile
		// beside the player, another boundary (2) far away. FAR one first,
		// again to observe the sort.
		final int[] bndId = {2, 1};
		final int[] bndAbsX = {140, 121};
		final int[] bndAbsZ = {660, 650};
		final int[] bndDir = {1, 0};

		public int boundCount() {
			return bndId.length;
		}

		public int boundId(int i) {
			return bndId[i];
		}

		public int boundX(int i) {
			return bndAbsX[i];
		}

		public int boundZ(int i) {
			return bndAbsZ[i];
		}

		public int boundDir(int i) {
			return bndDir[i];
		}

		public int[] boundScreenPoint(int i) {
			return projectionsVisible ? new int[]{260 + i, 130 + i} : null;
		}

		public void interactBound(int i, int command) {
			events.add("bound x=" + bndAbsX[i] + " z=" + bndAbsZ[i]
					+ " dir=" + bndDir[i] + " cmd=" + command);
		}

		// Two ground items, deliberately far-first so the snapshot sort is tested.
		final int[] groundId = {10, 27};
		final int[] groundAbsX = {130, 121};
		final int[] groundAbsZ = {650, 650};

		public int groundItemCount() {
			return groundId.length;
		}

		public int groundItemId(int i) {
			return groundId[i];
		}

		public int groundItemX(int i) {
			return groundAbsX[i];
		}

		public int groundItemZ(int i) {
			return groundAbsZ[i];
		}

		public void takeGroundItem(int i) {
			events.add("take x=" + groundAbsX[i] + " z=" + groundAbsZ[i]
					+ " id=" + groundId[i]);
		}

		public void useItem(int slot) {
			events.add("eat slot=" + slot);
		}

		public boolean walkTowardTile(int absX, int absZ) {
			if (!routeAvailable) {
				return false;
			}
			events.add("walk x=" + absX + " z=" + absZ);
			return true;
		}

		public void sendLocalChat(String text) {
			events.add("chat-local text=" + text);
		}

		public void sendPrivateChat(String target, String text) {
			events.add("chat-private target=" + target + " text=" + text);
		}

		public boolean clickPointer(int x, int y, int button) {
			events.add("click x=" + x + " y=" + y + " button=" + button);
			return true;
		}

		public void showLocalMessage(String text) {
			events.add("shown " + text);
		}
	}

	public static void main(String[] args) {
		String dir = args[0];
		String mode = args[1];
		int ticks = args.length > 2 ? Integer.parseInt(args[2]) : 1;
		ReflexBridge bridge = new ReflexBridge(Paths.get(dir));
		FakeHost host = new FakeHost();
		bridge.recordMessage("game", false, "", "Welcome to the \"quoted\" world");
		if ("state-chat".equals(mode)) {
			bridge.recordMessage("local", true, "Nearby Friend", "Try the east door");
			bridge.recordMessage("private", true, "Far Friend", "I can help from here");
		}
		if ("state-active".equals(mode)) {
			host.walking = true;
			host.inCombat = true;
			host.npcDialogueOpen = true;
		}
		if ("state-dialogue".equals(mode)) {
			bridge.recordMessage("quest", false, "", "Guide: What can I do for you?");
		}
		if ("state-player-dialogue".equals(mode)) {
			bridge.recordMessage("quest", false, "Player", "What can I do for you?");
		}
		if ("state-out".equals(mode) || "exec-out".equals(mode)) {
			host.loggedIn = false;
		}
		if ("exec-offscreen".equals(mode)) {
			host.projectionsVisible = false;
		}
		if ("exec-no-route".equals(mode)) {
			host.routeAvailable = false;
		}
		if ("exec-closed".equals(mode)) {
			host.shopOpen = false;
			host.bankOpen = false;
		}
		if ("hurt".equals(mode)) {
			host.hitsNow = 3;
		}
		if ("fail5".equals(mode)) {
			host.failing = true;
			for (int i = 0; i < 7; i++) {
				bridge.tick(host);
			}
			System.out.println("disabled=" + bridge.isDisabled());
		} else {
			for (int i = 0; i < ticks; i++) {
				bridge.tick(host);
			}
		}
		for (String event : host.events) {
			System.out.println(event);
		}
	}
}
