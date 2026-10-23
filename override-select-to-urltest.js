// FlClash 脚本覆写：订阅「导入即可用」
// 作用：把订阅配置里手动选择（type: select）的策略组改成自动测速
//      （type: url-test），每次更新订阅后自动重新生效，不用再逐组点节点。
// 用法：FlClash 里把该订阅的「拓展」切到「脚本」模式，新建脚本粘贴本文件
//      全部内容并选中该脚本即可。详细步骤见 OVERRIDE-usage.md。
// 安全闸门（2026-10-23 用户拍板，PDF 审查冲3）：
//   ① 成员含 DIRECT / REJECT 的组不转换——这类组转自动后 DIRECT 延迟最低
//      会被常驻选中，等于流量直连破防，保持手动最安全；
//   ② 转换时把机场塞的假节点（名字含「剩余流量 / 到期 / 官网」）和 2 倍以上
//      高倍率节点剔出测速候选池（只剔订阅 proxies 里实名的节点，嵌套组名与
//      来自 provider 的成员无法核实、一律保留）；剔完为空且无 use 的组不转换；
//   ③ 转换后的组显式写 lazy: true，没流量时不空跑测速。
// 其余口径不变：已有自动机制的组、规则、节点本身一律不动；空组跳过
// （改空组会让内核加载报错）。

const main = (config) => {
  const TEST_URL = "http://www.gstatic.com/generate_204"; // 测速地址
  const INTERVAL = 300; // 测速间隔（秒）
  const TOLERANCE = 50; // 容差（毫秒）：别的节点快出这么多才切换，防来回跳

  const FAKE_KEYWORDS = ["剩余流量", "到期", "官网"];
  const RATIO_RE =
    /(?:^|[^0-9])([2-9]|\d{2,})(?:\.\d+)?\s*[x×倍]|(?:[x×]\s*([2-9]|\d{2,})(?:\.\d+)?)/i;
  const isFakeOrPricey = (name) =>
    FAKE_KEYWORDS.some((k) => name.includes(k)) || RATIO_RE.test(name);

  const groups = config["proxy-groups"];
  if (Array.isArray(groups)) {
    const groupNames = new Set(
      groups.map((g) => g && g.name).filter((n) => typeof n === "string")
    );
    const proxyNames = new Set(
      (Array.isArray(config.proxies) ? config.proxies : [])
        .map((p) => p && p.name)
        .filter((n) => typeof n === "string")
    );
    for (const group of groups) {
      if (!group || typeof group !== "object") continue;
      if (group.type !== "select") continue;
      const hasProxies =
        Array.isArray(group.proxies) && group.proxies.length > 0;
      const hasUse = Array.isArray(group.use) && group.use.length > 0;
      if (!hasProxies && !hasUse) continue;
      // 闸门①：含 DIRECT / REJECT 的组保持手动
      if (
        hasProxies &&
        group.proxies.some((m) => m === "DIRECT" || m === "REJECT")
      ) {
        continue;
      }
      // 闸门②：剔除假节点与高倍率节点（仅限 proxies 实名节点）
      if (hasProxies) {
        const kept = group.proxies.filter(
          (m) => groupNames.has(m) || !proxyNames.has(m) || !isFakeOrPricey(m)
        );
        if (kept.length === 0 && !hasUse) continue; // 剔完为空则不转换
        group.proxies = kept;
      }
      group.type = "url-test";
      if (!group.url) group.url = TEST_URL;
      if (!group.interval) group.interval = INTERVAL;
      if (group.tolerance == null) group.tolerance = TOLERANCE;
      group.lazy = true; // 闸门③：显式开启懒测速
    }
  }
  return config;
};
