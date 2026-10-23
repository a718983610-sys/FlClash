import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/manager/manager.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pages/pages.dart';

Widget buildManagerStack({
  required bool isDesktop,
  required Future<void> Function(List<ConnectivityResult> results)
  onConnectivityChanged,
  Stream<ProcessSignal>? terminateSignals,
  required Widget child,
}) {
  final platformApp = isDesktop
      ? WindowHeaderContainer(child: child)
      : VpnManager(child: child);
  final state = AppStateManager(
    child: CoreManager(
      child: ConnectivityManager(
        onConnectivityChanged: onConnectivityChanged,
        child: platformApp,
      ),
    ),
  );
  final platformState = isDesktop
      ? WindowManager(
          terminateSignals: terminateSignals,
          child: TrayManager(
            child: HotKeyManager(child: ProxyManager(child: state)),
          ),
        )
      : AndroidManager(child: TileManager(child: state));
  return AppEnvManager(
    child: LocaleManager(
      child: StatusManager(child: ThemeManager(child: platformState)),
    ),
  );
}

class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

class ApplicationState extends ConsumerState<Application> {
  Timer? _autoUpdateProfilesTaskTimer;
  bool _preHasVpn = false;
  // Windows can only watch SIGINT and SIGHUP.
  final _terminateSignals = system.isDesktop && !system.isWindows
      ? ProcessSignal.sigterm.watch()
      : null;

  @override
  void initState() {
    super.initState();
    SystemNavigator.setFrameworkHandlesBack(true);
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      if (globalState.navigatorKey.currentContext != null) {
        await bootstrap.attach();
      } else {
        exit(0);
      }
      _autoUpdateProfilesTask();
      _initLink();
      if (!safeModeBuild) {
        unawaited(app?.initShortcuts());
      }
    });
  }

  void _initLink() {
    linkManager.initAppLinksListen((url) async {
      unawaited(window?.show());
      final message = currentAppLocalizations.createProfileFromUrlTip(url);
      final parts = message.split(url);
      final res = await dialogs.showMessage(
        title: currentAppLocalizations.addProfile,
        message: TextSpan(
          children: [
            TextSpan(text: parts.first),
            TextSpan(
              text: url,
              style: TextStyle(
                color: context.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: context.colorScheme.primary,
              ),
            ),
            if (parts.length > 1) TextSpan(text: parts.last),
          ],
        ),
      );
      if (res != true) return;
      unawaited(
        ref.read(profilesActionProvider.notifier).addProfileFromLink(url),
      );
    });
  }

  void _autoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer = Timer(const Duration(minutes: 20), () async {
      await ref.read(profilesActionProvider.notifier).autoUpdateProfiles();
      await ref.read(resourcesActionProvider.notifier).autoUpdate();
      if (!mounted) {
        return;
      }
      _autoUpdateProfilesTask();
    });
  }

  Future<void> _handleConnectivityChanged(
    List<ConnectivityResult> results,
  ) async {
    commonPrint.log('connectivityChanged ${results.toString()}');
    unawaited(systemDnsCoordinator?.resync() ?? Future.value());
    unawaited(ref.read(systemActionProvider.notifier).updateLocalIp());
    final hasVpn = results.contains(ConnectivityResult.vpn);
    if (_preHasVpn == hasVpn) {
      ref.read(routeTrackerProvider.notifier).bumpHostEpoch();
    }
    _preHasVpn = hasVpn;
  }

  @override
  Widget build(context) {
    return Consumer(
      builder: (_, ref, child) {
        final locale = ref.watch(
          appSettingProvider.select((state) => state.locale),
        );
        final themeProps = ref.watch(themeSettingProvider);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: globalState.navigatorKey,
          onNavigationNotification: (_) => true,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            AppUiLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          builder: (context, child) {
            return ThemeCrossFade(
              child: buildManagerStack(
                isDesktop: system.isDesktop,
                onConnectivityChanged: _handleConnectivityChanged,
                terminateSignals: _terminateSignals,
                child: RemoteFocusAdapter(
                  enabled: system.isTV,
                  floatingKeyboard: app?.floatingKeyboard,
                  child: child!,
                ),
              ),
            );
          },
          scrollBehavior: const BaseScrollBehavior(),
          title: appName,
          locale: getLocaleForString(locale),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          themeMode: themeProps.themeMode,
          theme: watchAppTheme(ref, Brightness.light),
          darkTheme: watchAppTheme(ref, Brightness.dark),
          themeAnimationStyle: AnimationStyle.noAnimation,
          home: KeyboardInsetHold(child: child!),
        );
      },
      child: const QfAgreementGate(child: HomePage()),
    );
  }

  @override
  void dispose() {
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    super.dispose();
  }
}

/// QFClash first-launch agreement gate (house rule): full-screen agreement,
/// checkbox-gated accept button, decline exits the app. Acceptance persists
/// in SharedPreferences and re-prompts ONLY when [agreementVersion] bumps.
/// Agreement copy: docs/user-agreement-v2.md is the finalized source
/// (version 2.0, 14 articles); [qfAgreementText] below is its verbatim
/// plain-text rendering (Markdown marks stripped for the Text widget).
class QfAgreementGate extends StatefulWidget {
  const QfAgreementGate({super.key, required this.child});

  final Widget child;

  /// Agreement text version (matches the finalized copy, currently
  /// '2.0'). Bump when the agreement text changes -> everyone
  /// re-confirms once.
  static const String agreementVersion = '2.0';
  static const String _prefKey = 'qf_agreement_accepted_version';

  @override
  State<QfAgreementGate> createState() => _QfAgreementGateState();
}

class _QfAgreementGateState extends State<QfAgreementGate> {
  bool? _accepted;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final stored = prefs.getString(QfAgreementGate._prefKey);
      setState(
        () => _accepted = stored == QfAgreementGate.agreementVersion,
      );
    });
  }

  Future<void> _accept() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      QfAgreementGate._prefKey,
      QfAgreementGate.agreementVersion,
    );
    if (mounted) setState(() => _accepted = true);
  }

  void _exitApp() {
    if (Platform.isAndroid) {
      SystemNavigator.pop();
    } else {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accepted = _accepted;
    if (accepted == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (accepted) return widget.child;
    return Scaffold(
      appBar: AppBar(title: const Text('QFClash 用户使用协议')),
      body: SafeArea(
        child: Column(
          children: [
            const Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: Text(qfAgreementText),
              ),
            ),
            CheckboxListTile(
              value: _checked,
              onChanged: (v) => setState(() => _checked = v ?? false),
              title: const Text('我已阅读并同意上述协议'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  OutlinedButton(
                    onPressed: _exitApp,
                    child: const Text('不同意并退出'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _checked ? _accept : null,
                      child: const Text('同意并进入'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Agreement body shown by the gate: finalized user agreement v2.0
/// (docs/user-agreement-v2.md), full 14-article text.
const String qfAgreementText = '''
QFClash 用户使用协议

协议版本：2.0
生效日期：2026-10-23
适用应用：QFClash 安卓版、QFClash Windows 版

欢迎使用 QFClash。请在使用前仔细阅读本协议全部内容。你勾选"我已阅读并同意"并点击"同意并进入"，即表示你已阅读、理解并接受本协议；如不同意任何一条，请立即退出并卸载本软件。


一、名词解释

1. 本软件：指 QFClash 安卓版与 Windows 版，含随版本发布的全部组件、文档（含《QFClash 应用使用详细报告》PDF）。
2. 维护者：指 QFClash 的开发与维护方，联系方式见第十四条。
3. 订阅：指用户自行从第三方获得的代理服务配置（含订阅链接、配置文件、节点信息）。订阅不是本软件提供的。
4. 官方仓库：指本软件的源代码与安装包发布页面，地址见第十四条。

二、本软件是什么、不是什么

1. 本软件是基于开源项目 FlClash 与 mihomo 内核二次开发的网络代理工具软件，源代码按 GPL-3.0 协议在官方仓库公开。
2. 本软件仅提供工具本身：它不运营服务器，不提供、不销售、不赠送任何节点、线路、流量或订阅，不保证连接任何网络。
3. 本软件与 Clash、Clash Verge、Shadowrocket、FlClash 等名称所指的项目或公司无隶属、代理或合作关系；上述名称仅在本协议与软件说明中作技术来源说明。
4. 本软件图标右下角的安卓机器人标志、Windows 窗户标志为各自权利方商标，仅用于区分安装包适用的平台，不表示与谷歌、微软存在任何关系。

三、协议的确认与变更

1. 本协议是你与维护者之间关于使用本软件的完整约定，取代此前一切口头或书面沟通。
2. 首次打开本软件会展示本协议，必须完成勾选同意后才能使用全部功能。
3. 维护者可根据需要修订协议。每次修订都会提高协议版本号，并在应用内重新向你展示、重新征得同意；未经你重新同意，新版协议对你不生效。
4. 如果你是未成年人，请在监护人陪同下阅读并由监护人决定是否同意。

四、软件的取得与更新

1. 请仅从官方仓库下载本软件。从其他渠道获得的安装包可能被篡改，维护者对其真实性、完整性与后果不承担责任。
2. 每个安装包均使用维护者的专属签名。无法通过签名校验的安装包不是官方发布，请勿安装。
3. 应用内"检查更新"只指向官方仓库对应平台的发布页；更新包必须与已安装版本签名一致才能覆盖安装，更新不会删除你的本地配置与数据。
4. 维护者可随时停止某一历史版本的维护。旧版本仍可使用，但已知问题只在新版本中修复。

五、订阅与第三方服务

1. 你导入的订阅、节点及一切配置，均来自你与第三方服务商之间的约定，与维护者无关。
2. 第三方服务的中断、涨价、变更、终止、跑路、被封禁，以及由此造成的任何损失，均与本软件和维护者无关，本软件不提供担保、仲裁或赔偿。
3. 你应确保你获得、导入的订阅与配置来源合法；因配置内容引发的纠纷由你与第三方解决。
4. 软件内显示的流量用量、到期时间等订阅信息，来自订阅服务商返回的数据，仅供参考，以服务商账单为准。
5. 本软件不会自动购买、续费任何第三方服务，也不会代你向第三方付款。

六、使用规范

使用本软件，你承诺不做以下事情：

1. 违反你所在地或服务器所在地法律法规的任何行为；
2. 侵害他人合法权益，包括但不限于隐私、知识产权、名誉权；
3. 攻击、扫描、入侵他人网络或设备，发送垃圾信息，实施欺诈；
4. 将本软件或其安装包进行商业转售、出租，或冒用 QFClash 名义对外发布、收费；
5. 对本软件进行以违法为目的的破解、篡改或植入恶意代码；
6. 删除或修改本软件内的开源许可声明、原项目署名、协议文本与版本信息。

如发现你违反上述规范，维护者有权在本软件的后续版本中采取限制措施；造成损失的，你应承担相应法律责任。

七、知识产权与开源许可

1. 本软件的源代码按 GPL-3.0 协议授权，你享有该协议授予的复制、修改与分发权利，同时必须履行该协议规定的义务（含保留许可证与署名、以相同协议公开修改后的源代码）。
2. 本软件使用的 FlClash、mihomo 等开源组件，其权利归各自作者所有，适用其随附许可证。
3. QFClash 的名称、图标与界面素材由维护者设计，其使用以官方仓库发布为准；未经许可，不得用于商业宣传或冒充官方。

八、数据与隐私

1. 本软件没有账号系统，不需要注册，不要求提供姓名、手机号等身份信息。
2. 以下数据仅保存在你的设备本地（应用私有目录）：订阅链接与配置、节点选择、流量统计、测速记录、软件设置、日志。本软件不收集、不上传、不出售这些数据。
3. 本软件不集成任何第三方广告、统计或行为追踪组件。软件内仅有 QFClash 自身的介绍与宣传内容，出现在"关于"页等固定位置，不弹窗、不影响操作。
4. 本软件仅在以下情形联网（代理流量除外）：你主动点击检查更新、导入或更新订阅时，向官方仓库或你的订阅地址发出请求。请求内容仅为完成该功能所必需，不包含你的身份信息。
5. 诊断日志只存在本地。你主动导出并发给维护者排障时，日志可能包含节点名称、服务器地址等配置信息，请在发送前自行检查；维护者收到后仅用于排障，不作其他用途。
6. 卸载本软件会删除全部本地数据；覆盖安装更新会保留数据。你也可随时在软件内清空配置与统计。

九、免责声明

1. 本软件按"现状"和"可用状态"提供，不作任何明示或暗示的保证，包括但不限于适销性、特定用途适用性、持续可用性与无错误。
2. 网络能否连通、速度与延迟，取决于你的订阅、运营商与网络环境，本软件不作承诺。软件内测速与延迟数字是本机测量结果，与实际体验可能有差异。
3. 因使用或无法使用本软件导致的直接或间接损失（含数据丢失、业务中断、第三方索赔），维护者在法律允许范围内不承担责任。
4. 本软件可能存在未知缺陷。维护者会尽力修复已知重要问题，但不承诺修复时间与结果。
5. 因不可抗力（含自然灾害、政策变化、运营商或云服务商变更）导致的服务或更新中断，维护者不承担责任。

十、责任限制

在法律允许的最大范围内，维护者就本软件承担的全部责任，以你因本软件实际遭受的直接损失为限；本软件为免费软件，你未向维护者支付任何费用，维护者不对间接、偶然或预期利益损失负责。

十一、协议终止与停止使用

1. 你可随时通过卸载本软件终止本协议，本地数据随卸载删除。
2. 维护者停止维护或发布新版，不影响你已安装版本在本地的继续使用，但维护者无义务为已停止维护的版本提供支持。
3. 本协议终止后，第五条、第七条、第九条、第十条继续有效。

十二、法律适用与争议解决

1. 本协议的订立、执行与解释，适用维护者所在地法律。
2. 因本协议或本软件产生的争议，双方应先通过第十四条联系方式友好协商；协商不成的，任何一方可向维护者所在地有管辖权的法院提起诉讼。

十三、其他

1. 本协议任一条款被认定无效，不影响其他条款的效力。
2. 本协议标题仅为阅读方便，不影响条款解释。
3. 《QFClash 应用使用详细报告》是本软件的使用说明文件，对功能细节的描述如与本协议冲突，以本协议为准。

十四、官方信息与联系方式

- 官方网站（项目仓库）：以"关于"页显示的官方仓库地址为准（仓库建成后填入实际地址）
- 联系方式（谷歌邮箱）：a718983610@gmail.com
- 当前协议版本：2.0
- 应用版本与使用报告版本：见"关于"页


本协议最终解释权归 QFClash 维护者所有。''';
