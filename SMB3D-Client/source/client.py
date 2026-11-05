import json
import os
from pathlib import Path
import queue
import sys
import tkinter as tk
from tkinter import ttk, messagebox
from tkinter.scrolledtext import ScrolledText

from network import Connection
from bridge import GameBridge
from deathlink import threshold


class App:
    def __init__(self, root):
        self.root = root
        self.events = queue.Queue()
        self.active = False
        self.closing = False
        data = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent)) / "client-contract-v1.json"
        contract = json.loads(data.read_text(encoding="utf-8"))
        self.bridge = GameBridge(contract, emit=lambda *event: self.events.put(event))
        self.connection = Connection(self.events, self.bridge)
        self.item_names = {v: k for k, v in contract["items"].items()}
        self.server = tk.StringVar(value="archipelago.gg:")
        self.slot = tk.StringVar(value="MeatPlayer")
        self.password = tk.StringVar()
        self.death_link = tk.BooleanVar()
        try:
            saved = json.loads((self.bridge.directory / 'deathlink-settings.json').read_text(encoding='utf-8'))
            initial_amnesty = threshold(saved.get('amnesty', 1))
        except (OSError, ValueError, TypeError):
            initial_amnesty = 1
        self.amnesty = tk.StringVar(value=str(initial_amnesty))
        self.valid_amnesty = initial_amnesty
        self.status = tk.StringVar(value="Not connected")
        self.checks = tk.StringVar(value="Checks: 0/???")
        self.item_count = tk.StringVar(value="Received items: 0")
        self.tags = tk.StringVar(value="Tags: AP")
        self.bridge_status = tk.StringVar(value="Waiting for game mod")
        self.build()
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.root.after(100, self.poll)

    def build(self):
        root = self.root
        root.title("Super Meat Boy 3D — Archipelago Client v1.0.0")
        root.geometry("720x700")
        root.minsize(620, 580)
        style = ttk.Style()
        style.theme_use("clam")
        style.configure("TFrame", background="#18212d")
        style.configure("TLabel", background="#18212d", foreground="#edf0f5", font=("Segoe UI", 10))
        style.configure("Title.TLabel", font=("Segoe UI", 20, "bold"))
        style.configure("Muted.TLabel", foreground="#aab9cc", font=("Segoe UI", 9))
        style.configure("TCheckbutton", background="#18212d", foreground="#edf0f5", font=("Segoe UI", 10))
        style.map("TCheckbutton", background=[("active", "#18212d")])
        style.configure("TButton", font=("Segoe UI", 10), padding=7)
        style.configure("TEntry", padding=7, font=("Segoe UI", 11))
        root.configure(background="#18212d")
        panel = ttk.Frame(root, padding=24)
        panel.pack(fill="both", expand=True)
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(11, weight=1)
        ttk.Label(panel, text="SUPER MEAT BOY 3D", style="Title.TLabel").grid(row=0, sticky="w")
        ttk.Label(panel, text="Archipelago client · game bridge preview", style="Muted.TLabel").grid(row=1, sticky="w", pady=(0, 18))
        self.entries = []
        for row, label, variable, secret in (
            (2, "Server / port", self.server, False),
            (4, "Slot name", self.slot, False),
            (6, "Password  ·  optional", self.password, True),
        ):
            ttk.Label(panel, text=label).grid(row=row, sticky="w", pady=(4, 3))
            entry = ttk.Entry(panel, textvariable=variable, show="●" if secret else "")
            entry.grid(row=row + 1, sticky="ew", pady=(0, 7))
            self.entries.append(entry)
        self.entries[0].focus_set()
        options = ttk.Frame(panel)
        options.grid(row=8, sticky="ew", pady=(6, 9))
        ttk.Checkbutton(options, text="DeathLink", variable=self.death_link, command=self.update_death_link).pack(side="left")
        ttk.Label(options, text='Send after', style='Muted.TLabel').pack(side='left', padx=(14, 5))
        self.amnesty_input = ttk.Spinbox(options, from_=1, to=100, width=4, textvariable=self.amnesty,
                                         command=self.update_amnesty)
        self.amnesty_input.pack(side='left')
        self.amnesty_input.bind('<FocusOut>', self.update_amnesty)
        self.amnesty_input.bind('<Return>', self.update_amnesty)
        ttk.Label(options, text='local deaths (1–100)', style='Muted.TLabel').pack(side='left', padx=5)
        actions = ttk.Frame(panel)
        actions.grid(row=9, sticky="ew")
        self.connect_button = ttk.Button(actions, text="Connect", command=self.toggle_connection)
        self.connect_button.pack(side="left")
        ttk.Button(actions, text="Launch game", command=self.launch_game).pack(side="left", padx=8)
        ttk.Label(actions, textvariable=self.status).pack(side="left", padx=8)
        counters = ttk.Frame(panel)
        counters.grid(row=10, sticky="ew", pady=(12, 8))
        ttk.Label(counters, textvariable=self.checks, style="Muted.TLabel").pack(side="left")
        ttk.Label(counters, textvariable=self.item_count, style="Muted.TLabel").pack(side="left", padx=20)
        notebook = ttk.Notebook(panel)
        notebook.grid(row=11, sticky="nsew")
        log_frame, items_frame = ttk.Frame(notebook), ttk.Frame(notebook)
        notebook.add(log_frame, text="Connection log")
        notebook.add(items_frame, text="Received items")
        self.log = ScrolledText(log_frame, height=8, wrap="word", font=("Segoe UI", 10),
                                bg="#111923", fg="#e0e7f0", insertbackground="white", relief="flat", state="disabled")
        self.log.pack(fill="both", expand=True)
        self.inventory = ttk.Treeview(items_frame, columns=("number", "item"), show="headings")
        self.inventory.heading("number", text="#")
        self.inventory.heading("item", text="Item")
        self.inventory.column("number", width=55, stretch=False)
        self.inventory.column("item", width=450)
        scrollbar = ttk.Scrollbar(items_frame, orient="vertical", command=self.inventory.yview)
        self.inventory.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        self.inventory.pack(fill="both", expand=True)
        ttk.Label(panel, textvariable=self.tags, style="Muted.TLabel").grid(row=12, sticky="w", pady=(8, 2))
        ttk.Label(panel, textvariable=self.bridge_status,
                  style="Muted.TLabel").grid(row=13, sticky="w")
        self.write_log("Ready. Enter your room address and slot name, then connect. Password may be blank.")

    def write_log(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", str(text) + "\n")
        if int(self.log.index("end-1c").split(".")[0]) > 1500:
            self.log.delete("1.0", "301.0")
        self.log.see("end")
        self.log.configure(state="disabled")

    def toggle_connection(self):
        if self.active:
            self.connection.stop()
            self.status.set("Disconnecting…")
            self.connect_button.configure(state="disabled")
            return
        try:
            amnesty = threshold(self.amnesty.get())
            self.connection.start(self.server.get(), self.slot.get(), self.password.get(), self.death_link.get(), amnesty)
        except ValueError as error:
            messagebox.showerror("Connection details", str(error), parent=self.root)
            return
        self.active = True
        self.connect_button.configure(text="Disconnect")
        self.inventory.delete(*self.inventory.get_children())
        self.item_count.set("Received items: 0")
        self.checks.set("Checks: 0/???")
        for entry in self.entries:
            entry.configure(state="disabled")

    def update_death_link(self):
        self.connection.set_death_link(self.death_link.get())
        if not self.active:
            self.tags.set("Tags: AP" + (", DeathLink" if self.death_link.get() else ""))

    def update_amnesty(self, event=None):
        try:
            value = threshold(self.amnesty.get())
        except ValueError:
            self.amnesty.set(str(self.valid_amnesty))
            self.root.bell()
            return
        if value != self.valid_amnesty:
            self.valid_amnesty = value
            self.connection.set_death_amnesty(value)
            self.write_log(f'DeathLink will send after every {value} local death(s). Counter reset.')
        try:
            self.bridge.atomic_write(self.bridge.directory / 'deathlink-settings.json', json.dumps({'amnesty': value}))
        except OSError:
            self.write_log('Could not save the DeathLink threshold; it remains active for this window.')

    def launch_game(self):
        try:
            os.startfile("steam://rungameid/3288210")
        except OSError as error:
            messagebox.showerror("Launch game", str(error), parent=self.root)

    def poll(self):
        while True:
            try:
                event, value = self.events.get_nowait()
            except queue.Empty:
                break
            if event == "status":
                self.status.set(value)
            elif event == "authenticated":
                self.status.set("Connected")
            elif event == "fatal":
                self.checks.set("Checks: 0/???")
                self.write_log(value)
                self.status.set("Connection refused")
            elif event == "log":
                self.write_log(value)
            elif event == "checks":
                self.checks.set(f"Checks: {value[0]}/{value[1]}")
            elif event == "tags":
                self.tags.set("Tags: " + ", ".join(value))
            elif event == "bridge":
                self.bridge_status.set(value)
            elif event == "items":
                self.inventory.delete(*self.inventory.get_children())
                for n, item in enumerate(value, 1):
                    self.inventory.insert("", "end", values=(n, self.item_names.get(item["item"], f"Unknown item {item['item']}")))
                self.item_count.set(f"Received items: {len(value)}")
            elif event == "lost":
                self.checks.set("Checks: 0/???")
                self.write_log("Connection lost. Reconnecting automatically; item history will be restored from the server.")
            elif event == "closed":
                self.checks.set("Checks: 0/???")
                self.active = False
                self.connect_button.configure(text="Connect", state="normal")
                for entry in self.entries:
                    entry.configure(state="normal")
                if self.status.get() != "Connection refused":
                    self.status.set("Not connected")
        if self.closing and not (self.connection.thread and self.connection.thread.is_alive()):
            self.root.destroy()
            return
        self.root.after(100, self.poll)

    def close(self):
        self.closing = True
        self.connection.stop()
        self.root.withdraw()


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == '--handshake-test':
        import traceback
        from network import tls_context
        from websockets.sync.client import connect
        try:
            uri = sys.argv[2]
            options = {'ssl': tls_context()} if uri.startswith('wss://') else {}
            with connect(uri, proxy=None, open_timeout=8, close_timeout=1, **options) as socket:
                packets = json.loads(socket.recv(timeout=5))
                result = {'success': True, 'packets': [p.get('cmd') for p in packets]}
        except Exception:
            result = {'success': False, 'error': traceback.format_exc()}
        Path(sys.argv[3]).write_text(json.dumps(result, indent=2), encoding='utf-8')
        sys.exit(0 if result['success'] else 1)
    root = tk.Tk()
    mutex_handle = None
    if sys.platform == 'win32' and '--smoke-test' not in sys.argv:
        import ctypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
        kernel.CreateMutexW.restype = ctypes.c_void_p
        mutex_handle = kernel.CreateMutexW(None, False, 'Local\\SMB3DArchipelagoClientBridge')
        if ctypes.get_last_error() == 183:
            root.withdraw()
            messagebox.showerror('Client already running', 'Another copy of this client is already running. Use its window or close it before opening a new one.')
            root.destroy()
            sys.exit(0)
    if "--smoke-test" in sys.argv:
        root.withdraw()
    app = App(root)
    if "--smoke-test" in sys.argv:
        root.update_idletasks()
        assert len(app.entries) == 3
        assert app.slot.get() == "MeatPlayer"
        assert app.entries[2].cget("show")
        assert "World 2 Access" in app.item_names.values()
        root.destroy()
    else:
        root.mainloop()
