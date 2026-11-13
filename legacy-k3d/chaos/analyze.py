#!/usr/bin/env python3
"""
analyze.py - Đọc kết quả một lần đo rồi in bảng và vẽ biểu đồ.

Cách dùng:
    python3 analyze.py <thư-mục-kết-quả-của-run_exp.sh> [chaos.csv]

Ví dụ:
    python3 analyze.py ../k6/results/e5_pod_20261104_193000_1234

Cần: pip install pandas matplotlib
Đọc:
    k6.json    - báo cáo tổng của K6 (req/s, P95, tỉ lệ lỗi)
    docker.csv - CPU/RAM từng container theo giây
    chaos.csv  - mốc thời gian gây lỗi / sửa lỗi (vẽ thành vạch đứng)
Ghi:
    bieudo-cpu-ram.png trong chính thư mục kết quả
"""
import json
import sys
from pathlib import Path

import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def doc_k6(path: Path):
    """In bảng tóm tắt từ k6.json."""
    if not path.exists():
        print(f"(không thấy {path.name})")
        return
    d = json.loads(path.read_text())
    m = d.get("metrics", {})

    def g(ten, khoa):
        return m.get(ten, {}).get(khoa)

    tong = g("http_reqs", "count")
    rps = g("http_reqs", "rate")
    p95 = g("http_req_duration", "p(95)")
    med = g("http_req_duration", "med")
    loi = g("http_req_failed", "rate")

    print("┌─ TÓM TẮT K6 ─────────────────────────────┐")
    print(f"│ Tổng số request   : {tong}")
    print(f"│ Thực tế (req/giây): {rps:.1f}" if rps else "│ Thực tế (req/giây): ?")
    print(f"│ Trung vị          : {med:.0f} ms" if med else "│ Trung vị          : ?")
    print(f"│ P95               : {p95:.0f} ms" if p95 else "│ P95               : ?")
    print(f"│ Tỉ lệ lỗi         : {loi*100:.2f} %" if loi is not None else "│ Tỉ lệ lỗi         : ?")
    print("└──────────────────────────────────────────┘")


def doc_docker(path: Path):
    """Đọc docker.csv -> DataFrame CPU% và RAM MiB theo thời gian."""
    if not path.exists():
        return None
    df = pd.read_csv(path)
    df["timestamp_utc"] = pd.to_datetime(df["timestamp_utc"], utc=True, errors="coerce")
    df = df.dropna(subset=["timestamp_utc"])
    df["cpu"] = df["cpu_percent"].astype(str).str.rstrip("%").astype(float, errors="ignore")

    def ram_mib(s):
        # "123.4MiB / 3.25GiB" -> 123.4
        try:
            v = str(s).split("/")[0].strip()
            for don_vi, he_so in (("GiB", 1024), ("MiB", 1), ("KiB", 1 / 1024),
                                  ("GB", 953.7), ("MB", 0.9537), ("kB", 1 / 1024)):
                if v.endswith(don_vi):
                    return float(v[: -len(don_vi)]) * he_so
            return float(v)
        except Exception:
            return float("nan")

    df["ram_mib"] = df["mem_usage"].map(ram_mib)
    return df


def doc_chaos(path: Path, t_dau, t_cuoi):
    """Lấy các mốc lỗi nằm trong khoảng thời gian của lần đo."""
    if not path or not path.exists():
        return pd.DataFrame()
    df = pd.read_csv(path)
    df["timestamp_utc"] = pd.to_datetime(df["timestamp_utc"], utc=True, errors="coerce")
    df = df.dropna(subset=["timestamp_utc"])
    return df[(df["timestamp_utc"] >= t_dau) & (df["timestamp_utc"] <= t_cuoi)]


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    thu_muc = Path(sys.argv[1]).expanduser()
    if not thu_muc.is_dir():
        print(f"❌ Không thấy thư mục {thu_muc}")
        sys.exit(1)

    chaos_csv = Path(sys.argv[2]).expanduser() if len(sys.argv) > 2 else \
        Path(__file__).resolve().parent / "results" / "chaos.csv"

    print(f"\n📂 {thu_muc}\n")
    doc_k6(thu_muc / "k6.json")

    df = doc_docker(thu_muc / "docker.csv")
    if df is None or df.empty:
        print("\n(không có docker.csv để vẽ biểu đồ)")
        return

    t_dau, t_cuoi = df["timestamp_utc"].min(), df["timestamp_utc"].max()
    moc = doc_chaos(chaos_csv, t_dau, t_cuoi)

    # tổng theo giây trên toàn bộ container k3d
    k3d = df[df["container"].astype(str).str.startswith("k3d-")]
    nguon = k3d if not k3d.empty else df
    theo_giay = nguon.groupby("timestamp_utc").agg(cpu=("cpu", "sum"),
                                                   ram=("ram_mib", "sum")).reset_index()

    print("\n┌─ TÀI NGUYÊN (tổng các container k3d) ────┐")
    print(f"│ CPU  trung bình : {theo_giay['cpu'].mean():.0f} %")
    print(f"│ CPU  đỉnh       : {theo_giay['cpu'].max():.0f} %")
    print(f"│ RAM  trung bình : {theo_giay['ram'].mean():.0f} MiB")
    print(f"│ RAM  đỉnh       : {theo_giay['ram'].max():.0f} MiB "
          f"({theo_giay['ram'].max()/1024:.2f} GiB)")
    print("└──────────────────────────────────────────┘")

    if not moc.empty:
        print("\n🕒 MỐC GÂY LỖI TRONG LẦN ĐO NÀY")
        for _, r in moc.iterrows():
            print(f"   {r['timestamp_utc']:%H:%M:%S}  {r['scenario']} {r['phase']}  ({r['target']})")

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 7), sharex=True)
    ax1.plot(theo_giay["timestamp_utc"], theo_giay["cpu"], linewidth=1)
    ax1.set_ylabel("CPU (%)")
    ax1.set_title(f"Tài nguyên trong lần đo: {thu_muc.name}")
    ax2.plot(theo_giay["timestamp_utc"], theo_giay["ram"], linewidth=1, color="tab:orange")
    ax2.set_ylabel("RAM (MiB)")
    ax2.set_xlabel("Thời gian (UTC)")

    for _, r in moc.iterrows():
        mau = "red" if r["phase"] == "start" else "green"
        for ax in (ax1, ax2):
            ax.axvline(r["timestamp_utc"], color=mau, linestyle="--", alpha=0.7)
        ax1.annotate(f"{r['scenario']} {r['phase']}", (r["timestamp_utc"], ax1.get_ylim()[1]),
                     rotation=90, va="top", fontsize=8, color=mau)

    for ax in (ax1, ax2):
        ax.grid(alpha=0.3)
    fig.tight_layout()
    out = thu_muc / "bieudo-cpu-ram.png"
    fig.savefig(out, dpi=130)
    print(f"\n🖼  Đã lưu biểu đồ: {out}")


if __name__ == "__main__":
    main()
