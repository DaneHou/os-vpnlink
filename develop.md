Project: os-vpnlink (The Traffic Orchestrator)
1. 核心定位 (The Mission)
os-vpnlink 是一个 OPNsense 插件，旨在消除 VPN Server 模式下的配置壁垒。它通过自动化 NAT、DNS 和策略路由，让拨入的远程设备（手机、电脑）能够像本地 LAN 设备一样，灵活地访问内网资源或借道其它 VPN Gateway 出行。

2. 三大核心逻辑模块
A. 基础链路自动化 (The Helper) —— 解决“通不通”
这是针对所有普通 VPN 用户的“救星”功能：

Auto-NAT: 检测到 VPN 拨入请求后，自动在 LAN2 或 WAN 接口生成 Outbound NAT。

DNS Sync: 自动探测 VPN 隧道网段，并静默将其加入 Unbound DNS 的 Access Control，无需用户手动输入 CIDR。

Interface Auto-Bind: 自动完成 WireGuard 实例到 OPNsense 逻辑接口的映射。

B. 设备级策略路由 (Device-Specific Steering) —— 解决“往哪走”
这是该插件最强悍的地方：让特定的 VPN 拨入 IP 走特定的出口。

逻辑： 用户可以在插件界面看到当前连接的 VPN 设备列表（基于 Static IP）。

操作： 针对特定设备（例如：你的手机 10.10.10.2），下拉选择一个 Gateway（例如：BA_VPNV4）。

后台动作： 插件自动在防火墙最顶层生成一条规则，强制该 Source IP 的流量转发至选定的 Gateway。

场景： 你的手机拨入家里的 OPNsense，然后你希望手机的所有流量再通过家里的 OpenVPN 节点出国。

C. 资源可见性管理 (Network Visibility) —— 解决“看得到”
Cross-Link: 一键勾选允许 VPN 网段访问特定的 LAN 网段（如 LAN2），插件自动处理防火墙双向放行规则。

Service Reflection: 自动处理本地服务的 MDNS 或特定广播发现，让 VPN 设备能“发现”内网的打印机或投影仪。

3. 界面设计预想 (UI/UX)
插件在 OPNsense 侧边栏会有一个独立菜单，主要包含两个 Tab：

Global Settings (全局设置):

[开启] 自动 DNS 授权

[开启] 自动 Outbound NAT 伪装

[下拉选择] 默认 DNS 服务器（如 192.168.68.1）

Device Links (设备联动):

显示一张列表，包含你的 WireGuard/OpenVPN 静态客户端：
| Device Name | Tunnel IP | Access LAN2 | Outbound Gateway |
| :--- | :--- | :--- | :--- |
| My_iPhone | 10.10.10.2 | [Check] | BA_VPNV4 (OpenVPN) |
| Work_Mac | 10.10.10.5 | [Uncheck]| WAN (Default) |

4. 技术实现的本质
这个插件实际上是一个 Config Generator (配置生成器)。它不修改 OPNsense 的内核代码，而是通过 Python 脚本：

读取现有的 VPN 客户端列表。

将用户的 UI 选择转化为 filter.conf (防火墙规则) 和 nat.conf (NAT规则) 中的条目。

通过 configd 重新加载服务。

5. 为什么这个 Project 很有趣？
因为它解决了 “VPN 嵌套” 的复杂性。通常要实现“手机 -> WG -> OPNsense -> OpenVPN -> Internet”这一串逻辑，需要极高的网络知识。

有了 os-vpnlink，你实际上是把 OPNsense 变成了一个中转站。你不仅是开发者，更是这个复杂流量网格的调度员。

结论： 这是一个非常符合“Power User”胃口的工具。如果 os-frp 是解决入站访问，那么 os-vpnlink 就是解决入站后的二次路由分发。
