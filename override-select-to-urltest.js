// FlClash 脚本覆写：订阅「导入即可用」
// 作用：把订阅配置里所有手动选择（type: select）的策略组批量改成自动测速
//      （type: url-test），每次更新订阅后自动重新生效，不用再逐组点节点。
// 用法：FlClash 里把该订阅的「拓展」切到「脚本」模式，新建脚本粘贴本文件
//      全部内容并选中该脚本即可。详细步骤见 OVERRIDE-usage.md。
// 说明：只改非空的 select 组；url-test/fallback 等已有自动机制的组、
//      规则、节点本身一律不动；空组跳过（改空组会让内核加载报错）。

const main = (config) => {
  const TEST_URL = "http://www.gstatic.com/generate_204"; // 测速地址
  const INTERVAL = 300; // 测速间隔（秒）
  const TOLERANCE = 50; // 容差（毫秒）：别的节点快出这么多才切换，防来回跳

  const groups = config["proxy-groups"];
  if (Array.isArray(groups)) {
    for (const group of groups) {
      if (!group || typeof group !== "object") continue;
      if (group.type !== "select") continue;
      const hasProxies =
        Array.isArray(group.proxies) && group.proxies.length > 0;
      const hasUse = Array.isArray(group.use) && group.use.length > 0;
      if (!hasProxies && !hasUse) continue;
      group.type = "url-test";
      if (!group.url) group.url = TEST_URL;
      if (!group.interval) group.interval = INTERVAL;
      if (group.tolerance == null) group.tolerance = TOLERANCE;
      if (group.lazy == null) group.lazy = true;
    }
  }
  return config;
};
