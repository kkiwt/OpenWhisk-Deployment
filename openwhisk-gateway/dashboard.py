import time
import requests
from rich.live import Live
from rich.table import Table
from rich.panel import Panel
from rich.console import Console

API_URL = "http://127.0.0.1:8080/admin/clusters"

def generate_table():
    try:
        data = requests.get(API_URL, timeout=2).json()
    except Exception:
        return Panel("[bold red]Gateway đang tắt hoặc không thể kết nối...[/bold red]", title="Lỗi Kết Nối")

    config = data["config"]
    nodes = data["nodes"]

    title = (f"🚀 OPENWHISK MULTI-CLUSTER GATEWAY 🚀\n"
             f"Thuật toán: [yellow]{config['policy'].upper()}[/] | "
             f"Cầu dao: [yellow]{'BẬT' if config['breaker_on'] else 'TẮT'}[/] | "
             f"Mục tiêu Ping: [cyan]{config['probe_action']}[/]")

    table = Table(title=title, show_header=True, header_style="bold magenta")
    table.add_column("Node", justify="center", style="cyan", no_wrap=True)
    table.add_column("Trạng thái", justify="center")
    table.add_column("Chế độ", justify="center")
    table.add_column("Độ trễ (Ping)", justify="right", style="green")
    table.add_column("Lỗi liên tục", justify="right", style="red")
    table.add_column("Tailscale IP", style="blue")

    for name, info in nodes.items():
        up_status = "[bold green]✅ Đang chạy[/]" if info["up"] else "[bold red]❌ Đã sập[/]"
        avail_status = "[bold green]Sẵn sàng[/]" if info["available"] else "[bold yellow]🛠 Bảo trì[/]"

        fails = str(info['fails'])
        if info['fails'] > 0:
            fails = f"[bold red]{fails}[/]"

        table.add_row(
            name.upper(),
            up_status,
            avail_status,
            f"{info['ewma_ms']} ms",
            fails,
            info["url"]
        )

    return table

if __name__ == "__main__":
    console = Console()
    try:
        # Chạy giao diện Live
        with Live(generate_table(), refresh_per_second=2, console=console) as live:
            while True:
                time.sleep(1)
                live.update(generate_table())

    # Bắt lỗi khi người dùng bấm Ctrl+C để thoát êm ái
    except KeyboardInterrupt:
        console.clear()
        console.print("[bold green]👋 Đã đóng bảng điều khiển Gateway một cách an toàn![/bold green]\n")