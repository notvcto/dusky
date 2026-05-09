#!/usr/bin/env python3
import os
import json
import subprocess
from pathlib import Path
from dataclasses import dataclass, field
from typing import Any, Literal

from textual import work, on, events
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal
from textual.widgets import Label, Input, Static, ListView, ListItem, Tabs, Tab
from textual.screen import ModalScreen
from textual.reactive import reactive
from textual.theme import Theme

from rich.text import Text
from rich.markup import escape

# =============================================================================
# HOT-RELOADING NATIVE JSON THEME ENGINE
# =============================================================================

THEME_FILE_PATH = Path("~/.config/matugen/generated/dusky_tui.json").expanduser()

def load_matugen_json(file_path: Path) -> dict[str, str]:
    colors = {
        "bg": "#111318", "fg": "#e1e2e9", "accent": "#a8c8ff", 
        "error": "#ffb4ab", "warning": "#bdc7dc", "success": "#dbbce1", "muted": "#43474e"
    }
    if not file_path.exists():
        return colors
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            data = json.load(f)
            colors.update(data)
    except Exception:
        pass
    return colors

THEME = load_matugen_json(THEME_FILE_PATH)

# =============================================================================
# SCHEMA & DATA DEFINITIONS
# =============================================================================

type ConfigType = Literal["bool", "int", "float", "string", "cycle", "action", "menu", "picker"]

@dataclass(kw_only=True)
class ConfigItem:
    label: str
    key: str
    scope: str = "DEFAULT"
    type_: ConfigType
    default: Any
    options: list[str] = field(default_factory=list)
    hints: list[str] = field(default_factory=list)
    min_val: float | None = None
    max_val: float | None = None
    step: float | None = None
    value: Any = None

    def __post_init__(self) -> None:
        if self.value is None:
            self.value = self.default

TABS = ["General", "Network", "Display", "System", "Audio", "Storage", "Security"]
SCHEMA: dict[int, list[ConfigItem]] = {
    0: [
        ConfigItem(label="Enable Daemon", key="service_enabled", type_="bool", default=True),
        ConfigItem(label="Timeout (ms)", key="timeout", type_="int", default=100, min_val=0, max_val=5000, step=50),
        ConfigItem(label="Log Prefix", key="log_prefix", type_="string", default="myapp_"),
        ConfigItem(label="Scale Factor", key="scale", type_="float", default=1.0, min_val=0.5, max_val=3.0, step=0.1),
    ],
    1: [
        ConfigItem(label="Hostname", key="hostname", type_="string", default="arch-linux"),
        ConfigItem(label="Protocol", key="protocol", type_="cycle", default="tcp", options=["tcp", "udp", "icmp"]),
        ConfigItem(label="Port", key="port", type_="int", default=8080, min_val=1, max_val=65535, step=1),
    ],
    3: [
        ConfigItem(label="Select Theme", key="demo_picker", type_="picker", default="Tokyo Night", 
                   options=["Catppuccin Mocha", "Nord", "Dracula", "Gruvbox", "Tokyo Night"],
                   hints=["Warm & Pastel", "Arctic Cold", "Vampire Dark", "Retro Groove", "Neon Lights"]),
        ConfigItem(label="Restart Daemon", key="demo_sudo", type_="action", default=""),
        ConfigItem(label="Shadow Color", key="color", type_="cycle", default="0xee1a1a1a", options=["0xee1a1a1a", "0xff000000"]),
    ]
}

# Auto-hydrate test data
for i in range(len(TABS)):
    if i not in SCHEMA: SCHEMA[i] = []
    for j in range(len(SCHEMA[i]), 35):
        cat = TABS[i]
        cycle_type = j % 3
        if cycle_type == 0:
            SCHEMA[i].append(ConfigItem(label=f"{cat} Flag {j}", key=f"{cat.lower()}_{j}", type_="bool", default=(j % 2 == 0)))
        elif cycle_type == 1:
            SCHEMA[i].append(ConfigItem(label=f"{cat} Buffer {j}", key=f"{cat.lower()}_{j}", type_="int", default=256 + j, min_val=0, max_val=4096, step=16))
        else:
            SCHEMA[i].append(ConfigItem(label=f"{cat} Path {j}", key=f"{cat.lower()}_{j}", type_="string", default=f"/etc/{cat.lower()}/conf.d"))

# =============================================================================
# MODALS & OVERLAYS
# =============================================================================

class TextInputOverlay(ModalScreen[str | None]):
    def __init__(self, prompt: str, default: str) -> None:
        super().__init__()
        self.prompt_text = prompt
        self.default_text = default

    def compose(self) -> ComposeResult:
        with Vertical(id="modal-dialog"):
            yield Label(self.prompt_text, id="modal-title")
            yield Input(value=self.default_text, id="modal-input")

    def on_mount(self) -> None:
        self.query_one(Input).focus()

    @on(Input.Submitted)
    def handle_submit(self, event: Input.Submitted) -> None:
        event.stop()
        self.dismiss(event.value)
        
    def on_key(self, event: events.Key) -> None:
        if event.key == "escape":
            self.dismiss(None)

class PickerScreen(ModalScreen[str | None]):
    def __init__(self, title: str, options: list[str], hints: list[str]) -> None:
        super().__init__()
        self.picker_title = title
        self.options = options
        self.hints = hints

    def compose(self) -> ComposeResult:
        with Vertical(id="picker-dialog"):
            yield Label(f"PICKER: {self.picker_title}", id="picker-title")
            yield ListView(*[ListItem(Label(f"{opt} - [italic {THEME['muted']}]{hint}[/]")) for opt, hint in zip(self.options, self.hints)], id="picker-list")
            yield Label(" [Enter] Select   [Esc] Cancel", id="picker-footer")

    def on_mount(self) -> None:
        self.query_one(ListView).focus()

    @on(ListView.Selected)
    def on_selected(self, event: ListView.Selected) -> None:
        idx = self.query_one(ListView).index
        if idx is not None:
            self.dismiss(self.options[idx])

    def on_key(self, event: events.Key) -> None:
        if event.key == "escape":
            self.dismiss(None)

# =============================================================================
# INTERACTIVE COMPONENTS
# =============================================================================

class ConfigRow(ListItem):
    def __init__(self, item: ConfigItem) -> None:
        super().__init__(classes="config-row")
        self.item = item
        self.can_focus = False 

    def compose(self) -> ComposeResult:
        with Horizontal():
            yield Label("➤", classes="row-cursor")
            yield Label(self.item.label, classes="row-label")
            yield Label(self.build_display(), classes="row-value")

    def on_click(self, event: events.Click) -> None:
        """Guarantees explicit left-click selection without relying on deep layout bubbling."""
        parent = self.parent
        if isinstance(parent, ListView):
            try:
                parent.index = parent.children.index(self)
                parent.focus()
            except ValueError:
                pass

    def build_display(self) -> str:
        val_str = str(self.item.value)
        def_str = str(self.item.default)
        
        dot_color = THEME["error"] if val_str != def_str else THEME["muted"]
        dot = f"[{dot_color}]●[/]"
        
        display_val = escape(val_str)
        match self.item.type_:
            case "bool":
                display_val = f"[{THEME['accent']}]ON[/]" if self.item.value else f"[{THEME['muted']}]OFF[/]"
            case "string":
                display_val = f"[italic {THEME['muted']}]Unset[/]" if val_str == "" else f"[{THEME['fg']}]{display_val}[/]"
                display_val = f"[{THEME['accent']}]\\[✎][/] {display_val}"
            case "action":
                display_val = f"[{THEME['accent']}]▶[/] press Enter"
            case "picker":
                display_val = f"[{THEME['accent']}]\\[+][/] {display_val}"
            case _:
                display_val = f"[{THEME['fg']}]{display_val}[/]"

        return f"{dot} : {display_val}"

    def update_display(self) -> None:
        self.query_one(".row-value", Label).update(self.build_display())

class Shortcut(Label):
    def __init__(self, key_text: str, label: str, action_name: str | None = None) -> None:
        super().__init__(classes="footer-shortcut")
        self.key_text = key_text
        self.label_text = label
        self.action_name = action_name

    def render(self) -> Text:
        txt = Text()
        txt.append(f"[{self.key_text}] ", style=THEME["accent"])
        txt.append(self.label_text, style=THEME["fg"])
        return txt

    def on_click(self) -> None:
        if self.action_name:
            getattr(self.app, f"action_{self.action_name}")()

class FileLink(Label):
    """Handles deep OS integration for GUI/CLI text editors."""
    path = "~/.config/myapp/settings.conf"
    
    def render(self) -> Text:
        txt = Text()
        txt.append(" File: ", style=THEME["accent"])
        txt.append(self.path, style=THEME["fg"] + " underline")
        return txt
        
    def on_click(self, event: events.Click) -> None:
        expanded_path = Path(self.path).expanduser().resolve()
        expanded_path.parent.mkdir(parents=True, exist_ok=True)
        expanded_path.touch(exist_ok=True)
        
        try:
            if event.button == 1:
                # Left Click -> GNOME Text Editor (Detached & Sandboxed Stdout/Stderr)
                subprocess.Popen(
                    ["gnome-text-editor", str(expanded_path)], 
                    start_new_session=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
            elif event.button == 3:
                # Right Click -> Suspend TUI, yield TTY to Neovim safely
                with self.app.suspend():
                    subprocess.run(["nvim", str(expanded_path)])
        except FileNotFoundError:
            if hasattr(self.app, "notify_status"):
                getattr(self.app, "notify_status")("Error: Editor executable not found in PATH.")

class AppFooter(Vertical):
    pagination_info = reactive("[1/35]")
    status_msg = reactive("")

    def compose(self) -> ComposeResult:
        with Horizontal(id="footer-controls"):
            yield Shortcut("Tab", "Category", "next_tab")
            yield Shortcut("r", "Reset Item", "reset_item")
            yield Shortcut("R", "Reset All", "reset_all")
            yield Shortcut("←/→ h/l", "Adjust")
            yield Label(self.pagination_info, id="pagination-label")
        with Horizontal(id="footer-secondary"):
            yield Shortcut("Enter", "Action", "submit_current")
            yield Shortcut("q", "Quit", "quit")
            yield Label(f"   [{THEME['muted']}]●[/] Default  [{THEME['error']}]●[/] Modified", id="footer-legend")
        
        with Horizontal(id="footer-bottom-row"):
            yield Label("", id="status-bar")
            yield FileLink(id="file-link")

    def watch_pagination_info(self, new_val: str) -> None:
        for label in self.query("#pagination-label"):
            label.update(new_val)

    def watch_status_msg(self, new_val: str) -> None:
        for bar in self.query("#status-bar"):
            for link in self.query("#file-link"):
                if new_val:
                    txt = Text()
                    txt.append(" Status: ", style=THEME["accent"])
                    txt.append(new_val, style=THEME["error"])
                    bar.update(txt)
                    bar.display = True
                    link.display = False
                else:
                    bar.display = False
                    link.display = True

# =============================================================================
# MAIN APPLICATION
# =============================================================================

class DuskyApp(App):
    CSS = """
    Screen { background: $background; }
    
    #main-box {
        width: 100%; height: 100%;
        border: solid $secondary;
        border-title-color: $primary;
        border-title-style: bold;
        border-title-align: center;
        background: transparent;
        padding: 0 1;
    }
    
    Tabs { height: 1; margin-bottom: 1; background: transparent; }
    Tabs > .underline { display: none; } 
    Tab { height: 1; padding: 0 1; color: $secondary; background: transparent; border: none; }
    Tab:hover { color: $text; }
    Tab.-active { color: $background; background: $primary; text-style: bold; border: none; }
    
    #content-list { height: 1fr; margin-bottom: 1; overflow-y: auto; overflow-x: hidden; scrollbar-size: 0 0; background: transparent; border: none; }
    
    .config-row { height: 1; padding: 0; background: transparent; }
    
    /* Hover State: Purely Visual Glow (Does NOT claim cursor or selection) */
    .config-row:hover { background: $primary 10%; }
    
    /* Highlight State: Persistent Selection */
    .config-row.-highlight { background: $primary 20%; }
    .config-row.-highlight > Horizontal > .row-cursor { color: $primary; }
    .config-row.-highlight > Horizontal > .row-label { color: $text; text-style: bold; }
    
    .row-cursor { width: 2; color: transparent; }
    .row-label { width: 35; color: $text; }
    
    #footer { height: 4; dock: bottom; border-top: solid $secondary; padding-top: 0; background: transparent; }
    #footer-controls { width: 100%; }
    #pagination-label { dock: right; color: $primary; text-style: bold; margin-right: 1; }
    
    .footer-shortcut { margin-right: 2; }
    .footer-shortcut:hover { text-style: bold; color: $primary; }
    #footer-legend { color: $text; }
    
    #footer-bottom-row { margin-top: 1; }
    #file-link:hover { text-style: bold; color: $primary; }
    
    TextInputOverlay, PickerScreen { align: center middle; background: rgba(0, 0, 0, 0.75); }
    #modal-dialog { width: 50; height: 7; background: $background; border: solid $primary; padding: 1 2; }
    #modal-title { color: $primary; margin-bottom: 1; }
    Input { border: none; background: transparent; color: $text; border-bottom: solid $primary; }
    Input:focus { border: none; border-bottom: solid $primary; }
    
    #picker-dialog { width: 60; height: 15; background: $background; border: solid $primary; padding: 1 2; }
    #picker-title { color: $primary; margin-bottom: 1; text-style: bold; border-bottom: solid $secondary; }
    #picker-list { height: 1fr; scrollbar-size: 0 0; background: transparent; border: none; }
    #picker-list > ListItem { height: 1; background: transparent; }
    #picker-list > ListItem.-highlight { background: $primary 20%; }
    #picker-footer { color: $primary; margin-top: 1; }
    """

    BINDINGS = [
        Binding("q,ctrl+c", "quit", "Quit", priority=True),
        Binding("tab", "next_tab", "Next Tab", priority=True),
        Binding("shift+tab", "prev_tab", "Prev Tab", priority=True),
        Binding("j,down", "cursor_down", "Down", priority=True),
        Binding("k,up", "cursor_up", "Up", priority=True),
        Binding("g", "scroll_top", "Top", priority=True),
        Binding("G", "scroll_bottom", "Bottom", priority=True),
        Binding("h,left,backspace", "adjust(-1)", "Adjust Down", priority=True),
        Binding("l,right", "adjust(1)", "Adjust Up", priority=True),
        Binding("r", "reset_item", "Reset", priority=True),
        Binding("R", "reset_all", "Reset All", priority=True),
        Binding("ctrl+d,page_down", "page_down", "Page Down", priority=True),
        Binding("ctrl+u,page_up", "page_up", "Page Up", priority=True),
    ]

    current_tab_idx: int = 0
    last_theme_mtime: float = 0.0
    tab_states: dict[int, int] = {}

    def compose(self) -> ComposeResult:
        with Vertical(id="main-box"):
            yield Tabs(*[Tab(name, id=f"tab-{i}") for i, name in enumerate(TABS)])
            yield ListView(id="content-list")
            yield AppFooter(id="footer")

    def on_mount(self) -> None:
        self.query_one("#main-box").border_title = " Generic System Config Editor v7.0.3 "
        self.apply_theme_to_engine()
        self.load_tab_content(0)
        self.set_interval(0.5, self.watch_theme_file)

    def watch_theme_file(self) -> None:
        try:
            current_mtime = THEME_FILE_PATH.stat().st_mtime
            if current_mtime > self.last_theme_mtime:
                self.last_theme_mtime = current_mtime
                new_theme = load_matugen_json(THEME_FILE_PATH)
                THEME.update(new_theme) 
                
                self.apply_theme_to_engine()
                
                for row in self.query(ConfigRow):
                    row.update_display()
                for shortcut in self.query(Shortcut):
                    shortcut.refresh()
                    
                for footer in self.query(AppFooter):
                    for legend in footer.query("#footer-legend"):
                        legend.update(f"   [{THEME['muted']}]●[/] Default  [{THEME['error']}]●[/] Modified")
                for link in self.query(FileLink):
                    link.refresh()
        except OSError:
            pass

    def apply_theme_to_engine(self) -> None:
        self._theme_revision = getattr(self, "_theme_revision", 0) + 1
        theme_name = f"dusky_matugen_rev{self._theme_revision}"

        custom_theme = Theme(
            name=theme_name,
            primary=THEME["accent"],
            secondary=THEME["muted"],
            background=THEME["bg"],
            surface=THEME["bg"],
            warning=THEME["warning"],
            error=THEME["error"],
            success=THEME["success"],
            foreground=THEME["fg"],
        )
        
        self.register_theme(custom_theme)
        self.theme = theme_name

    def load_tab_content(self, idx: int) -> None:
        lv = self.query_one("#content-list", ListView)
        
        # Save the layout state of the outgoing tab
        if lv.children:
            self.tab_states[self.current_tab_idx] = lv.index if lv.index is not None else 0
            
        self.current_tab_idx = idx
        lv.clear()
        
        items = SCHEMA.get(idx, [])
        for item in items:
            lv.append(ConfigRow(item))
            
        if items:
            # We defer focus and index restoration to ensure the DOM has fully populated, 
            # locking the CSS highlight onto the exact right item instantly.
            def restore_state() -> None:
                lv.focus()
                saved_idx = self.tab_states.get(idx, 0)
                lv.index = min(saved_idx, len(items) - 1)
                self.query_one(AppFooter).pagination_info = f"[{lv.index + 1}/{len(items)}]"
            
            self.call_after_refresh(restore_state)
        else:
            self.query_one(AppFooter).pagination_info = "[0/0]"

    @on(Tabs.TabActivated)
    def handle_tab_activated(self, event: Tabs.TabActivated) -> None:
        idx = int(event.tab.id.split("-")[1])
        if idx != self.current_tab_idx:
            self.load_tab_content(idx)

    @on(ListView.Highlighted)
    def update_pagination(self, event: ListView.Highlighted) -> None:
        lv = event.list_view
        idx = lv.index if lv.index is not None else 0
        total = len(lv.children)
        self.query_one(AppFooter).pagination_info = f"[{idx + 1}/{total}]"

    def notify_status(self, msg: str) -> None:
        self.query_one(AppFooter).status_msg = msg
        self.set_timer(3, lambda: setattr(self.query_one(AppFooter), 'status_msg', ""))

    # --- Actions mapped to bindings ---

    def action_next_tab(self) -> None: self.query_one(Tabs).action_next_tab()
    def action_prev_tab(self) -> None: self.query_one(Tabs).action_previous_tab()
    def action_cursor_down(self) -> None: self.query_one(ListView).action_cursor_down()
    def action_cursor_up(self) -> None: self.query_one(ListView).action_cursor_up()
    def action_scroll_top(self) -> None: self.query_one(ListView).index = 0
    
    def action_scroll_bottom(self) -> None:
        lv = self.query_one(ListView)
        if lv.children:
            lv.index = len(lv.children) - 1
            
    def action_page_down(self) -> None:
        lv = self.query_one(ListView)
        if not lv.children: return
        idx = lv.index if lv.index is not None else 0
        lv.index = min(len(lv.children) - 1, idx + 10)
        
    def action_page_up(self) -> None:
        lv = self.query_one(ListView)
        if not lv.children: return
        idx = lv.index if lv.index is not None else 0
        lv.index = max(0, idx - 10)

    def action_adjust(self, direction: int) -> None:
        lv = self.query_one(ListView)
        if lv.highlighted_child is None: return
        
        row = lv.highlighted_child
        item = row.item
        
        match item.type_:
            case "bool":
                item.value = not item.value
            case "int" | "float":
                step = item.step or 1
                new_val = item.value + (direction * step)
                if item.min_val is not None: new_val = max(item.min_val, new_val)
                if item.max_val is not None: new_val = min(item.max_val, new_val)
                item.value = round(new_val, 6) if item.type_ == "float" else new_val
            case "cycle":
                try: idx = item.options.index(item.value)
                except ValueError: idx = 0
                item.value = item.options[(idx + direction) % len(item.options)]
            case _: return
            
        row.update_display()
        self.notify_status(f"Updated {item.label}")

    def action_reset_item(self) -> None:
        lv = self.query_one(ListView)
        if lv.highlighted_child:
            row = lv.highlighted_child
            row.item.value = row.item.default
            row.update_display()
            self.notify_status(f"Reset {row.item.label}")

    def action_reset_all(self) -> None:
        for row in self.query(ConfigRow):
            row.item.value = row.item.default
            row.update_display()
        self.notify_status(f"Reset all items in {TABS[self.current_tab_idx]}")

    def action_submit_current(self) -> None:
        lv = self.query_one(ListView)
        if lv and lv.highlighted_child:
            self.handle_selection(ListView.Selected(lv, lv.highlighted_child, lv.index))

    @on(ListView.Selected)
    def handle_selection(self, event: ListView.Selected) -> None:
        row = event.item
        item = row.item
        
        match item.type_:
            case "bool": self.action_adjust(1)
            case "string": self.prompt_string(row)
            case "action":
                if item.key == "demo_sudo":
                    self.notify_status("Acquiring Sudo... Simulated daemon restart.")
            case "picker": self.prompt_picker(row)

    @work
    async def prompt_string(self, row: ConfigRow) -> None:
        new_val = await self.push_screen(TextInputOverlay(f"Enter new {row.item.label}:", str(row.item.value)))
        if new_val is not None:
            row.item.value = new_val
            row.update_display()
            self.notify_status(f"Written: {row.item.label} = {new_val}")

    @work
    async def prompt_picker(self, row: ConfigRow) -> None:
        new_val = await self.push_screen(PickerScreen(row.item.label, row.item.options, row.item.hints))
        if new_val is not None:
            row.item.value = new_val
            row.update_display()
            self.notify_status(f"Selected: {new_val}")

if __name__ == "__main__":
    app = DuskyApp()
    app.run()
