# Group Manager

**A smarter way to manage scene and global groups in the Godot editor.**

Group Manager replaces the friction of Godot's built-in Groups dock with a purpose-built panel that gives you full visibility into every group in your scene, lets you assign nodes with a single checkbox, and keeps your workflow uninterrupted with live search, undo/redo support, and a dockable UI you can place wherever you want.

---

## Installation

### From the downloaded ZIP

1. Download and extract the ZIP archive.
2. Copy the `addons/group_manager` folder into your project's `addons/` directory. If your project does not already have an `addons/` folder, create one at the project root (next to `project.godot`). The final path should be:
   ```
   your_project/
   └── addons/
       └── group_manager/
           ├── plugin.cfg
           ├── plugin.gd
           └── group_manager_dock.gd
   ```
3. Open the editor and go to **Project → Project Settings → Plugins**.
4. Find **Group Manager** in the list and toggle **Enable**.
5. The **Groups** panel appears in the bottom bar, alongside Output and Debugger. Use the location dropdown in the panel's toolbar to move it if you prefer a side dock.

### From the Godot Asset Library

1. In the editor, open the **AssetLib** tab at the top of the window.
2. Search for **Group Manager** and open its page.
3. Click **Download**, then **Install** — the installer places the files under `addons/group_manager` automatically.
4. Enable the plugin via **Project → Project Settings → Plugins** as described above.

### Verifying it works

Once enabled, open any scene and click the **Groups** tab in the bottom panel. If the scene has nodes assigned to groups, they appear immediately. If not, the panel shows "No groups found" until you create one with the **+ Group** button.

---

## Features

**Scene and global groups, side by side**
Groups are split into two clearly labelled sections — Scene Groups and Global Groups — so you always know the scope of what you're working with. Global groups registered in Project Settings show a `global` badge and are visible across every scene in your project.

**Create groups with scope control**
The New Group dialog lets you choose between Scene or Global scope at creation time. Global groups are written directly to `project.godot` via ProjectSettings and appear in Project Settings → Globals → Groups immediately. No need to navigate away from your scene.

**Fuzzy search at two levels**
A group filter bar at the top narrows the group list as you type using fuzzy matching — type `plr` to find `player_group`. Expand any group and a second search bar filters its node list the same way, with matched characters highlighted in amber so you can see exactly what matched.

**Checkbox node membership**
Expand any group to see every node in the scene with a checkbox. Checked nodes are members. Members always sort to the top with their node type icon shown alongside their name. Uncheck to remove — the group stays listed even with zero members.

**Empty groups that persist**
Godot discards groups the moment their last member is removed. Group Manager saves all explicitly created scene groups to a lightweight `.gm_groups` file next to your scene, so empty groups survive scene reloads and editor restarts.

**Full undo/redo integration**
Every membership change, group rename, and group deletion is registered with `EditorUndoRedoManager`. Ctrl+Z works exactly as expected, including across scene history.

**Flexible dock placement**
A dropdown in the toolbar lets you move the panel between five locations without restarting the editor: Bottom Panel, Left (Upper), Left (Lower), Right (Upper), and Right (Lower). Your choice is saved to EditorSettings and restored on next launch.

---

## Usage

**Create a group** — Click **+ Group**, enter a name, and choose **Scene** or **Global** scope. Global scope reveals an optional description field that is stored alongside the group in Project Settings.

**Assign nodes** — Click the `▶` arrow on any group row to expand it. Every node in the current scene is listed with a checkbox. Check a node to add it to the group; uncheck to remove it. Current members sort to the top.

**Rename a group** — Click the `✎` icon on a group row. Scene groups update in the `.gm_groups` file; global groups have their Project Settings key moved and their description preserved. Any live node members are re-tagged automatically.

**Delete a group** — Click the `✕` icon. For global groups, this removes the entry from Project Settings as well as from any nodes in the current scene. The confirmation dialog states clearly when you are deleting a project-wide global group.

**Search** — Use the top filter bar to narrow the group list, or the per-group search bar (visible when a group is expanded) to filter its node list. Both use fuzzy matching.

**Move the dock** — Use the location dropdown in the toolbar to reposition the panel at any time.

---

## Requirements

- Godot **4.2 or later**.
- Node type icons require Godot **4.3 or later**. On 4.2 the plugin runs normally but node rows show without their type icons, because `EditorInterface.get_editor_theme()` was introduced in 4.3. The call is guarded, so no error occurs on 4.2.

Tested against Godot 4.7 stable (released June 18, 2026).

---

## Notes on version control

Scene groups created via Group Manager are saved to a `.gm_groups` file alongside your `.tscn`. It is safe to commit this file to version control — collaborators will see the same pre-declared empty groups. If you prefer to keep it local, add the following line to your `.gitignore`:

```
*.gm_groups
```

Global groups are written to `project.godot` under the `[global_group]` section and behave identically to groups created through the built-in Project Settings interface. Since `project.godot` is normally committed, global groups are shared with your team automatically.

---

## Troubleshooting

**The Groups panel does not appear after enabling.** Godot occasionally caches dock layout. Disable the plugin, restart the editor, then re-enable it. If it still does not show, use **Editor → Editor Layout → Reset to Default Layout**.

**A global group I created in Project Settings is not shown.** Click the refresh button (`↺`) in the toolbar. The panel reads global groups from the live ProjectSettings and from `project.godot` on disk; a refresh re-scans both.

**Node icons are missing.** This is expected on Godot 4.2. Upgrade to 4.3 or later to see node type icons.

---

## License

See the `LICENSE` file included with this plugin.

---

*Made by Accessive Game Studio*
