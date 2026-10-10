# nftables.sh

Debian / Ubuntu 上的 nftables 端口转发管理脚本：交互菜单完成端口转发规则的添加 / 查看 / 删除，
支持批量端口范围与 TCP、UDP、TCP+UDP 协议选择，并自动处理 nftables 的安装、服务启动、
开机自启与规则持久化。

## 一键运行

```shell script
curl -fsSL https://raw.githubusercontent.com/Zephyr177/nftables.sh/main/nftables.sh -o nftables.sh && sudo bash nftables.sh
```

wget 版：

```shell script
wget -qO nftables.sh https://raw.githubusercontent.com/Zephyr177/nftables.sh/main/nftables.sh && sudo bash nftables.sh
```

## 菜单

```
==================== nftables 端口转发管理 ====================
nftables: 已安装   服务: 运行中   开机自启: 已启用   转发规则: 2 条
------------------------------------------------------------------------
  1) 添加端口转发 (支持端口范围, TCP/UDP/TCP+UDP)
  2) 查看当前转发规则
  3) 删除转发规则
  4) 清空所有转发规则
  5) 开启 / 关闭 nftables 开机自启
  0) 退出
------------------------------------------------------------------------
```

顶部状态栏实时显示：nftables 是否安装、服务是否运行、是否开机自启、当前转发规则条数。

## 功能说明

- **启动自检**：未安装 nftables 时询问是否用本脚本 `apt-get install -y nftables`；
  服务未运行（或未开启开机自启）时询问是否 `systemctl start nftables`，
  并在启动前列出会因 `flush ruleset` 被清除的表（Docker / hysteria / fail2ban 等加载的表）。
- **批量端口转发**：外部端口支持单个（`8080`）或范围（`53000-54000`）；
  目标端口留空表示端口保持不变，填写时数量必须与外部端口一致（如 `53000-54000` → `63000-64000`）。
- **协议选择**：TCP / UDP / TCP+UDP，一次添加自动生成对应规则。
- **查看规则**：列出编号、协议、外部端口、转发目标，并显示 SNAT(masquerade)、持久化文件、
  开机恢复与开机自启状态。
- **删除规则**：支持 `1`、`1 3`、`2-4`、`all` 等写法，按 nftables handle 精确删除。
- **开机自启**：`systemctl enable nftables` / `systemctl disable nftables`。

## 工作原理

- 转发规则放在独立表 `ip pf`：`prerouting` 链做 DNAT，`postrouting` 链自动维护
  `ct status dnat masquerade`，与 Docker 使用的 `ip nat` 表、系统 `inet filter` 表互不干扰；
  masquerade 保证被转发流量的回程经过本机，同网段 / 跨网段都能正常访问。
- 每次改动实时写入内核，并立即导出到 `/etc/nftables.d/portforward.nft`；
  该文件由 `/etc/nftables.conf` 中的 `include` 引入（首次写入前自动备份原配置到
  `/etc/nftables.conf.bak.时间戳`）。
- 导出的配置文件以 `add table` + `flush table` 开头，nftables 重复加载不会产生重复规则。
- 重启后由 `nftables.service` 加载该 include 恢复规则，因此需要开启开机自启，
  规则才能在重启后自动恢复。

## 注意事项

- 仅支持 IPv4。
- `systemctl stop nftables` 在 Debian 上等价于 `nft flush ruleset`（单元文件里 `ExecStop` 就是这么写的），
  会清空包括本表在内的全部规则；只想关掉开机自启请用 `systemctl disable nftables`。
- 若同机运行 Docker / hysteria / fail2ban 等自行加载 nftables 规则的服务：
  `systemctl start|restart nftables` 会先执行 `flush ruleset`，它们的规则会立即消失，
  需要重启对应服务才会恢复（脚本会在启动前把受影响的表列出来）。
- 未开启开机自启时，规则在重启后不会自动恢复。

## 可自定义

脚本头部支持用环境变量覆盖，便于测试或多实例部署：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `NFT_TABLE_NAME` | `pf` | 转发规则专用表名 |
| `NFT_PF_CONF` | `/etc/nftables.d/portforward.nft` | 持久化规则文件 |
| `NFT_MAIN_CONF` | `/etc/nftables.conf` | 主配置文件（include 目标） |
| `NFT_SERVICE` | `nftables` | systemd 单元名 |
| `NFT_SYSTEMD_DIR` | `/run/systemd/system` | systemd 运行标志目录 |

## 卸载 / 还原

```shell script
sudo nft delete table ip pf
sudo sed -i '\|^include "/etc/nftables.d/portforward.nft"$|d' /etc/nftables.conf
sudo rm -rf /etc/nftables.d
sudo systemctl disable nftables    # 不要加 --now：stop 会 flush 整个规则集
```

也可以直接用首次写入前留下的备份覆盖还原：`sudo cp -a /etc/nftables.conf.bak.* /etc/nftables.conf`

## 已验证环境

Debian 13 (trixie) / nftables v1.1.3 / root 实测：

- 外部访问：`58000-58001` 端口范围（TCP+UDP）、`58080 → 目标:58000` 端口映射均正常，
  未转发端口无响应（对照组）；
- UDP 转发往返正常，conntrack 记录可见 DNAT 到目标 + SNAT 回本机；
- 与 Docker 的 iptables-nft 规则共存互不影响；持久化文件连续 3 次 `nft -f` 加载后规则数不变（幂等）；
- `systemctl start nftables`（即 `flush ruleset` + include）后规则自动恢复，转发仍然可用。

## License

[Unlicense](LICENSE) — public domain.
