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
import 'qf/qf_gate.dart';

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
      child: const QfAgreementGate(child: QfSessionGate(child: HomePage())),
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
/// (version 3.0); [qfAgreementText] below is its verbatim
/// plain-text rendering (Markdown marks stripped for the Text widget).
class QfAgreementGate extends StatefulWidget {
  const QfAgreementGate({super.key, required this.child});

  final Widget child;

  /// Agreement text version (matches the finalized copy, currently
  /// '2.0'). Bump when the agreement text changes -> everyone
  /// re-confirms once.
  static const String agreementVersion = '3.0';
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
      setState(() => _accepted = stored == QfAgreementGate.agreementVersion);
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
      return const Scaffold(body: Center(child: CommonCircleLoading.page()));
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

/// Agreement body shown by the gate: finalized user agreement v3.0
/// (docs/user-agreement-v3.md).
const String qfAgreementText = '''
QFClash 用户使用协议

协议版本：3.0
生效日期：自 QFClash 1.0.0 发布之日起生效（见文末生效说明）
适用应用：QFClash 安卓版、QFClash Windows 版

欢迎使用 QFClash。请在使用前仔细阅读本协议全部内容。你勾选"我已阅读并同意"并点击"同意并进入"，即表示你已阅读、理解并接受本协议；如不同意任何一条，请立即退出并卸载本软件。


一、名词解释

1. 本软件：指 QFClash 安卓版与 Windows 版，含随版本发布的全部组件、文档（含《QFClash 应用使用详细报告》PDF）。
2. 维护者：指 QFClash 的开发与维护方，联系方式见第二十条。
3. 订阅：指用户自行从第三方获得的代理服务配置（含订阅链接、配置文件、节点信息）。订阅不是本软件提供的。
4. 官方仓库：指本软件的源代码与安装包发布页面，源代码获取方式见第二十条。
5. 官方网站：指维护者公布的 QFClash 官方网站，地址以本软件"关于"页公布的为准。
6. 账号：指你通过本软件或官方网站注册、登录的 QFClash 账号。安卓版、Windows 版与官方网站共用同一账号体系，同一账号在各端通用。
7. 访客模式：指不注册、不登录，以受限方式使用本软件的模式，规则见第八条。
8. 积分：指本软件内按第九条规则记录的虚拟计数，仅用于在本软件内兑换公示的权益，不具有货币属性。
9. 论坛：指官方网站提供的 QFClash 论坛，规则见第十三条。

二、本软件是什么、不是什么

1. 本软件是基于开源项目 FlClash 与 mihomo 内核二次开发的网络代理工具软件，源代码按 GPL-3.0 协议在官方仓库公开。
2. 本软件仅提供工具本身：它不运营代理服务器，不提供、不销售、不赠送任何节点、线路、流量或订阅，不保证连接任何网络。
3. 本软件自 1.0.0 版起提供可选的账号、积分与兑换服务。该等服务由维护者运营，仅用于账号登录、积分记录与权益兑换，不改变前款定性：账号服务不是代理服务，维护者不因提供账号服务而成为任何订阅或节点的提供方。
4. 本软件与 Clash、Clash Verge、Shadowrocket、FlClash 等名称所指的项目或公司无隶属、代理或合作关系；上述名称仅在本协议与软件说明中作技术来源说明。
5. 本软件图标右下角的安卓机器人标志、Windows 窗户标志为各自权利方商标，仅用于区分安装包适用的平台，不表示与谷歌、微软存在任何关系。
6. 服务地域：本软件及相关服务计划仅在允许提供和使用本软件相关功能的国家或地区提供。维护者可根据适用法律法规及合规要求，对特定地区的下载、更新或相关功能采取限制措施。用户应遵守所在国家或地区适用的法律法规，并自行确认其使用行为是否合法；违反所在地法律法规使用所产生的一切后果，由用户自行承担。用户违反所在地法律法规或本协议的，维护者可按第十七条采取处置措施。本款仅用于说明服务范围与使用要求，不构成对任何地区合法性的保证，也不免除维护者依法应履行的许可、备案或其他义务。

三、协议的确认与变更

1. 本协议是你与维护者之间关于使用本软件的完整约定，取代此前一切口头或书面沟通。
2. 首次打开本软件会展示本协议，必须完成勾选同意后才能使用全部功能。
3. 维护者可根据需要修订协议。每次修订都会提高协议版本号，并按你已同意的协议版本号进行比对：协议更新后，无论你是新安装还是从旧版本升级，首次打开新版本时都会重新向你展示协议全文，你须重新勾选同意后方可继续使用；未经你重新同意，新版协议对你不生效。
4. 如果你是未成年人，请在监护人陪同下阅读并由监护人决定是否同意。

四、软件的取得

1. 请仅从官方仓库下载本软件。从其他渠道获得的安装包可能被篡改，维护者对其真实性、完整性与后果不承担责任。
2. 每个安装包均使用维护者的专属签名（Windows 安装包的代码签名以发布说明的标注为准）。无法通过签名校验的安装包不是官方发布，请勿安装。
3. 更新包必须与已安装版本签名一致才能覆盖安装，更新不会删除你的本地配置与数据。版本更新与停止服务的规则见第十二条。

五、订阅与第三方服务

1. 你导入的订阅、节点及一切配置，均来自你与第三方服务商之间的约定；你与第三方之间的权利义务，由双方的约定及适用法律确定。
2. 维护者不控制第三方服务的运营、收费、线路、可用性与持续经营情况，不对第三方服务作出保证。第三方服务发生中断、涨价、变更、终止等情况或产生纠纷的，你应根据与第三方的约定处理；但法律规定维护者应当承担责任的，不因本条而免除。
3. 你应确保你获得、导入的订阅与配置来源合法；因配置内容引发的纠纷由你与第三方解决。
4. 软件内显示的流量用量、到期时间等订阅信息，来自订阅服务商返回的数据，仅供参考，以服务商账单为准。
5. 本软件不会自动购买、续费任何第三方服务，也不会代你向第三方付款。

六、账号注册与登录

1. 登录自愿。本软件不强制注册或登录：进入应用时你可以选择登录后使用，也可选择以访客模式使用（见第八条）。登录用户可使用全部功能并参与积分与兑换；访客模式的功能与时长受限。
2. 邮箱注册。你可使用电子邮箱注册账号，流程为：填写邮箱 → 接收并填写邮箱验证码 → 设置密码。未通过邮箱验证的账号不能登录。验证码仅用于注册、找回密码、更换邮箱与异常验证等场景，日常登录不使用验证码。验证码的发送频率与有效期以页面提示为准。
3. 谷歌登录。你可选择使用谷歌账号一键登录。使用谷歌登录，视为你授权维护者在谷歌返回的信息范围内读取你的邮箱地址，用于验证你的邮箱。通过 Google 登录验证邮箱后，仍须设置账户 ID 与登录密码方可完成注册；完成注册后，同一邮箱地址通过谷歌登录与通过邮箱注册的，视为同一账号。谷歌登录的可用性取决于谷歌服务的可用状态，维护者不对其可用性作出保证。
4. 账号安全。你应妥善保管账号与密码，并对以你的账号进行的操作负责。登录状态采用访问令牌与刷新令牌机制，在正常情况下长期保持、无需反复登录；长期未使用或设备环境明显变化时，系统可能要求你完成轻验证。身份验证分为两层：（一）环境异常验证，你可在安全中心开启或关闭；开启时，在新设备登录，或已登记设备的登录国家发生突变时，系统将要求通过邮箱验证码验证，已经通过验证的设备不会因同一环境因素反复触发；出国旅行时登录国家发生变化，触发环境异常验证属于正常现象。（二）强制安全复核，在刷新令牌被重用、短时间多次登录失败等高风险情形下，系统将强制要求重新验证身份；该复核不可关闭，不受环境异常验证开关影响。绑定邮箱无法使用、无法接收验证码时，你可发送邮件至 a718983610@gmail.com 申请人工核验。发现账号被盗用或存在其他安全风险时，请立即修改密码或通过第二十条联系方式与维护者联系。
5. 安全中心。登录后，你可在安全中心管理账号，包括：修改密码（修改后其他设备的登录状态失效）、更换绑定邮箱（新旧邮箱均须验证；邮箱不可用时可通过第二十条联系方式申请人工核验）、查看登录设备并远程下线、注销账号（见第七条第 7 款）。
6. 直连说明。账号相关的登录、注册与验证请求由本软件直接向账号服务器发出，不经代理节点转发；节点故障不影响登录的进行。
7. 账号服务的定位。代理、订阅、规则等核心功能不依赖账号状态运行；登录入口处保留"设置 → 关于 → 检查更新"的通道，检查更新仅连接官方仓库，不依赖账号服务器。维护者如停止账号服务，将依照第十七条处理，并提供不依赖账号的版本供你继续使用本地功能。

七、账号数据与隐私

1. 本地数据。以下数据仅保存在你的设备本地（应用私有目录，用户主动使用云端备份功能时除外）：订阅链接与配置、节点选择、流量统计、测速记录、软件设置、诊断日志。维护者不主动收集、不上传、不出售该等数据。卸载本软件后，应用私有目录中的数据通常会随卸载删除；你主动导出并保存在其他位置的文件可能继续存在，请在卸载前自行检查并删除不再需要的文件。覆盖安装更新会保留数据；你也可随时在软件内清空配置与统计。
2. 账号数据的收集。当你注册、登录并使用账号功能时，维护者会在服务器侧处理以下数据：
   （1）账号资料：你自设的账户 ID、邮箱地址、经不可逆加密处理的密码、账号状态与注册时间；
   （2）登录与设备信息：登录设备的设备名称、平台类型（安卓/Windows）、最近活跃时间、登录地区，以及由设备安装标识与硬件特征组合计算的设备标识哈希；
   （3）会话与安全记录：登录令牌的签发与使用记录、验证码的发送与核验记录、登录与安全操作日志；
   （4）积分与兑换记录：计时心跳记录、积分流水（每笔增减的时间、事由与余额）、兑换订单与审核记录，以及你兑换时填写的发放信息（USDT 收款地址或礼品卡接收邮箱）；
   （5）你主动提交的内容：意见反馈内容与你填写的联系方式、论坛帖子与回复内容；
   （6）个人资料：你设置的昵称与头像（在本软件、论坛与好友场景中公开显示）；
   （7）好友与加密聊天数据：好友关系与申请记录、加密聊天的公钥包与消息密文，以及经你的账号密码派生密钥加密的聊天密钥备份（维护者无法解密，见《隐私说明》）。聊天消息的中继密文在账号存续期间保存，并随账号注销一并删除。你在软件内删除聊天会话时，删除的是你本人的聊天密文归档与你本人设备上的副本；你本人在其他设备上的副本，将在该设备联网并同步后删除；对方持有的聊天记录副本不受该删除操作影响；
   （8）通行密钥公钥凭证：你创建的通行密钥的公钥、名称、创建时间与最近使用时间（私钥不上传至服务器）；
   （9）订阅备份密文：你主动使用云端备份功能时上传的订阅备份密文。该备份采用端到端加密，服务器仅保存密文，维护者无法解密；忘记账户密码将导致订阅备份无法恢复；
   （10）聊天密文归档（历史保险库）：你主动使用聊天记录云同步功能时上传的加密归档条目，以及经你的账号密码派生密钥包裹后的保险库密钥（维护者无法解密，见《隐私说明》）；
   （11）设置备份密文：你主动使用设置云备份功能时上传的加密设置备份（同步范围见《隐私说明》）。
3. 数据的用途。前款数据仅用于：创建与维持账号、验证身份与保障账号安全、记录与结算积分、处理兑换与审核、提供好友与端到端加密聊天服务、处理反馈与论坛管理、防范作弊与滥用。设备标识哈希仅用于前述安全与防作弊目的，只保存哈希值，不保存可直接识别设备的原始特征。
4. 数据的存储。账号数据存储于维护者运营的账号服务器（当前采用 Cloudflare 提供的云服务，包括 Workers 与 D1 数据库）。存储地点与服务商如有重大变更，维护者将通过协议修订或官方公告告知。
5. 不做的事。本软件不集成任何第三方广告、统计或行为追踪组件，不出售、不出租你的账号数据，不将其用于与本软件无关的营销。软件内仅有 QFClash 自身的介绍与宣传内容，出现在"关于"页等固定位置，不弹窗、不影响操作。
6. 你的权利。你可通过安全中心查看与管理你的账号信息与登录设备；如需查询、更正或删除你的账号数据，或对数据处理有疑问，可通过第二十条联系方式提出，维护者将在核实身份后处理。
7. 注销与删除。你可随时在安全中心申请注销账号。注销申请提交后有 7 天冷静期，冷静期内登录账号即可撤销注销；冷静期届满后，维护者将删除你的服务器账号数据（包括订阅备份密文、聊天密文归档及包裹后的保险库密钥、设置备份密文、通行密钥公钥凭证与加密聊天密钥备份），删除后不可恢复。申请注销前，系统会明确提示：注销后账号积分将清零，未使用的兑换码将作废。 注销仅删除服务器账号数据，不影响你设备上的本地数据；如法律法规要求留存个别日志记录，该部分将在法定期限届满后删除。
8. 联网说明。你主动检查更新时，本软件会向官方仓库或相关发布服务发送请求，该等服务提供方可能按其适用的隐私规则处理你的 IP 地址、请求时间、客户端版本等连接信息。你导入或更新订阅时，本软件会向你指定的订阅地址发送请求，相应服务商及网络服务提供方可能获取该请求所需的连接信息，其处理行为由其自身规则约束，维护者无法控制。你主动导出并发送诊断日志的，维护者仅将日志用于处理相应问题，并合理限制其访问、使用与保存范围。

八、访客模式

1. 进入方式。未登录状态下，你可在阅读访客说明弹窗并确认后进入访客模式。弹窗将明示：访客模式无积分与兑换权益，功能与每日可用时长受限。
2. 可用功能。访客模式下仅可使用：订阅导入、连接、规则、全局模式、节点切换；"关于"、检查更新等基础入口保留。积分、兑换、账号与安全中心等其余功能不可用，访客使用不记录积分。
3. 每日额度。访客每日可用时长为 2 小时，按连接处于有效使用状态的时间累计。额度由服务器按设备标识哈希登记与核算，重新安装本软件、清除应用数据或修改设备时间均不会重置额度；额度于次日（服务器时间）自动恢复。
4. 额度用完。当日额度用完时，本软件将同时断开代理连接并弹出提示窗口，告知额度已用完及登录后的权益；你可选择登录（登录完成后恢复全部功能且不再受访客额度限制）或暂不登录。暂不登录的，此后使用任何受限功能都会再次弹出该窗口，但"关于"中的检查更新始终可用。额度已用完的状态下重新打开本软件，须先经额度确认方可连接。

九、积分规则

1. 获得方式。登录用户在本软件处于连接有效使用状态（核心正在接管流量）时，按分钟累计使用时长；累计满 3 小时得 1 分，未满 3 小时的时长以待结算分钟保留不清零。积分进度可在积分页面查看。安卓版与 Windows 版共用同一账号积分；同一时段在两台设备同时使用的，重叠时段只计一份时长，不同時段正常累计。
2. 记账口径。积分由服务器记账，以服务器收到的计时记录与积分流水为准，客户端本地显示仅供参考；余额可由流水重新核算。每位用户可在积分页面查看余额、累计获得、累计消费与逐笔明细。
3. 上限。每个账号每日最多获得 8 分；每台设备每日产分上限同为 8 分，两项上限同时适用，任一达到即当日不再计分。
4. 不计分的情形。以下情形的时段不计积分：无实际流量的长时间挂机时段（连续 30 分钟无流量增量）；计时记录缺失、乱序或时间异常的时段；模拟器、改机、多开分身等异常环境下运行的时段（系统将提示"当前环境不计积分"，但不影响正常使用，不作封禁处理）。
5. 注册限制。为防范批量注册，同一设备 24 小时内最多成功注册 1 个账号，超限将进入 72 小时冷却，冷却期内该设备的注册请求将被拒绝；同一设备 7 天内注册达到 3 个账号的，将被标记并接受复核。
6. 禁止作弊。你不得以任何方式伪造、篡改计时记录或设备标识，不得批量注册账号、轮换账号在同一设备刷取积分，不得利用程序缺陷获取积分。
7. 处置与申诉。经核查存在作弊或违反本条行为的，维护者可视情节采取警告、清除违规积分、封禁账号、封禁设备等措施，处置将留存记录；被封禁的设备以任何账号登录都将被拒绝。如你对处置有异议，可发送邮件至 a718983610@gmail.com 申诉，维护者将人工复核并答复；申诉成立的，将解除处置或恢复相应积分。
8. 与所在地区无关。积分的累计不因用户所在的国家或地区而受限。福利兑换功能在部分国家或地区可能暂时不可用，兑换不可用不影响积分的累计与保留。

十、积分兑换

1. 兑换规则。你可使用积分兑换兑换页面公示的商品。商品的名称、所需积分、库存状态与兑换条件以兑换页面实时展示为准；维护者可根据运营情况上架、下架商品或调整所需积分，调整不影响已完成的兑换。
2. 兑换流程与发放方式。兑换前将弹出确认窗口，展示本次花费积分与兑换后余额；你确认后，系统校验余额与库存并扣除积分。即时发放商品的兑换码将当场展示并存入"我的兑换"记录；需人工审核的商品按第 3 款处理。美元奖励的发放方式为：5 美元奖励仅以 USDT 发放，不提供礼品卡方式；10 美元奖励可选择以 USDT 或礼品卡发放。选择 USDT 的，须填写 USDT（TRC20）收款地址；选择礼品卡的，须填写接收邮箱，该邮箱仅用于接收发放通知与发放信息，礼品卡兑换码在发放后绑定相应订单，须经双重核验后在"我的兑换"中查看。任一环节失败的，本次兑换自动取消，已扣积分自动退回并留有流水记录。
3. 人工审核。公示为需人工审核的商品（包括美元奖励等付费类权益），兑换申请提交后进入待审核状态，相应积分先行冻结；审核通过后发放，审核驳回的，冻结积分自动退回（经查实为作弊的驳回除外，处理见第九条第 7 款）。
4. 其他。积分不足时不可兑换，页面将提示还差积分数量；售罄或下架商品不可兑换。兑换码的使用规则与有效期以商品说明为准。

十一、使用规范

使用本软件与账号服务，你承诺不做以下事情：

1. 违反你所在地或服务器所在地法律法规的任何行为；
2. 侵害他人合法权益，包括但不限于隐私、知识产权、名誉权；
3. 攻击、扫描、入侵他人网络或设备，发送垃圾信息，实施欺诈；
4. 冒用 QFClash 官方身份发布软件、使用虚假官方签名或冒充官方更新渠道误导他人，或擅自使用 QFClash 的名称、图标与标识，使他人误认为未经授权的版本由官方发布（你在 GPL-3.0 及各组件许可证下享有的复制、修改与分发权利，不受本条限制，见第十四条）；
5. 对本软件进行以违法为目的的破解、篡改或植入恶意代码；
6. 删除或篡改本软件内的开源许可证文本、版权声明与原项目署名（保留该等信息是你履行开源许可证义务的一部分）；
7. 冒用他人账号或以其他不正当方式使用他人账号，批量注册账号，或干扰账号服务器、积分与兑换系统的正常运行；
8. 以任何方式绕过访客额度、封禁处置或其他依本协议实施的限制措施。

如发现你违反上述规范，维护者有权视情节采取警告、限制功能、清除违规积分、封禁账号或设备等措施；造成损失的，你应承担相应法律责任。

十二、版本更新与停止服务

1. 版本划分。主版本号变更为大版本（如 1.0.0 → 2.0.0），次版本号或修订号变更为小版本。本软件的更新在应用内完成：可直接在软件内下载并安装更新包，不跳转浏览器；更新弹窗展示本次更新内容，大版本更新与停止服务版本的更新窗口内设有下载进度条。
2. 小版本更新。小版本更新为自愿更新，更新弹窗可关闭，关闭后可继续使用当前版本；每次启动最多提示一次。历史版本的安装包保留在官方仓库发布页，你可自行下载。
3. 大版本强制更新。发布大版本后，上一个大版本的本软件在启动联网检查到新大版本时，将弹出强制更新窗口：该窗口不可关闭、无暂缓选项，不完成更新则无法继续使用本软件。完全无网络、检查不到更新时先行放行使用，一旦联网检查到新大版本即按本款执行。
4. 停止服务。本软件仅支持当前大版本与上一个大版本，以及以最新小版本为基准回退不超过 3 个的小版本。超出前述范围的版本即为停止服务版本：启动时将弹出"该版本已停止服务"窗口，该窗口不可关闭、无暂缓选项，不更新到受支持版本则无法继续使用。
5. 系统维护。维护者进行系统维护时，可开启维护状态：维护期间打开本软件将显示"系统维护中，请稍后再试"，本软件暂时不可用；维护结束、维护状态关闭后自动恢复使用。
6. 执行方式。版本支持范围与维护状态由维护者通过官方仓库发布的版本清单执行，客户端在启动时联网核对；离线时按本地缓存的清单执行，无缓存时先行放行。该机制不依赖账号服务器，账号服务不可用时不影响更新与停止服务的执行。手机端与电脑端实行同版本、同批发布、一起更新。

十三、意见反馈与官方论坛

1. 意见反馈。本软件内与官方网站均设有意见反馈（联系我们）入口。你填写并提交反馈后，反馈内容将自动发送至维护者邮箱并在服务器存档，维护者无需你另行发送邮件。反馈时可自愿填写联系方式以便回复；提交时系统将自动附带应用版本、平台信息，登录状态下将附带账号信息，以便定位问题。除前述用途外，反馈内容不作其他用途。为防范滥用，反馈提交设有频率与长度限制（同一设备每日最多 5 条，以页面提示为准）。
2. 论坛使用。官方网站设有论坛，与本软件共用账号体系：未登录仅可浏览，登录后方可发布帖子与回复。发帖与回复须遵守法律法规与本协议第十一条，并遵守官方网站公布的《QFClash 论坛审核规则》。
3. 内容审核。论坛实行自动审核：内容在发布时即时审核。含有政治敏感、广告引流、联系方式外泄、交易推广、色情擦边、赌博、诈骗、辱骂或违法敏感信息等违规内容的，将不予通过，并向发布者提示未通过的大类原因；部分情形（如新注册账号的首帖、含有外部链接的内容）将进入复核队列，复核通过后方可公开展示，复核期间仅发布者本人可见。
4. 论坛处置。违反论坛规则的，维护者可视情节对内容不予通过、转为复核或对账号采取禁言措施：30 天内累计被驳回 3 次的，禁言 7 天；累计 5 次的，禁言 30 天；累计 8 次的，永久禁言。论坛禁言仅限制论坛发言，不影响本软件账号的其他功能。详细审核标准与频率限制以《QFClash 论坛审核规则》为准；对审核或禁言有异议的，可通过意见反馈或第二十条联系方式申诉。

十四、知识产权与开源许可

1. 本软件的源代码按 GPL-3.0 协议授权，你享有该协议授予的复制、修改与分发权利，同时必须履行该协议规定的义务（含保留许可证与署名、以相同协议公开修改后的源代码）。
2. 本软件使用的 FlClash、mihomo 等开源组件，其权利归各自作者所有，分别适用其随附的许可证（例如 mihomo 采用 MIT 许可证）；分发本软件时，应分别保留各组件适用的许可证、版权声明与修改标记，不要将全部组件一概视为 GPL-3.0。
3. QFClash 的名称、图标与界面素材由维护者设计。任何人不得以易使他人误认其版本为官方版本、或误认其与维护者存在隶属、合作关系的方式，使用 QFClash 的名称、图标与标识；本款不影响你在开源许可证下使用源代码本身的权利。

十五、免责声明

1. 本软件按"现状"和"可用状态"提供，不作任何明示或暗示的保证，包括但不限于适销性、特定用途适用性、持续可用性与无错误。
2. 网络能否连通、速度与延迟，取决于你的订阅、运营商与网络环境，本软件不作承诺。软件内测速与延迟数字是本机测量结果，与实际体验可能有差异。
3. 账号、积分、兑换与论坛服务依赖账号服务器与第三方云服务的可用状态，可能因维护、故障或第三方原因中断或延迟；访客额度、积分与时长的核算以服务器记录为准。因前述中断造成的积分结算延迟，维护者将按服务器流水补正，但不对中断本身承担赔偿责任。
4. 因使用或无法使用本软件导致的直接或间接损失（含数据丢失、业务中断、第三方索赔），维护者在法律允许范围内不承担责任。
5. 本软件可能存在未知缺陷。维护者会尽力修复已知重要问题，但不承诺修复时间与结果。
6. 因不可抗力（含自然灾害、政策变化、运营商或云服务商变更）导致的服务或更新中断，维护者不承担责任。

十六、责任限制

在适用法律允许的范围内，维护者不对因第三方服务、用户不当操作、非维护者所能合理控制的网络故障或不可抗力造成的损失，承担超出法定范围的责任；维护者就本软件承担的责任以你实际遭受的直接损失为限，不对间接、偶然或预期利益损失负责。本协议任何内容均不排除或限制适用法律规定不得排除或限制的责任，包括依法应承担的人身损害责任，以及因故意或重大过失造成对方财产损失的责任。

十七、账号处置、协议终止与服务终止

1. 账号处置。你违反本协议或相关规则的，维护者可依第九条、第十一条、第十三条采取警告、清除违规积分、封禁账号、封禁设备、论坛禁言等措施，并保留依法追究责任的权利。封禁分级为：警告、封禁 7 天、封禁 30 天、永久封禁；累犯可直接跳级，情节严重者可直接永久封禁并封禁设备。维护者运行自动巡查系统，对刷取积分、批量注册、伪造数据、倒卖账号或兑换码、攻击服务等滥用行为自动检测与处置。封禁在服务器侧执行：被封禁的账号无法登录，被封禁的设备无法登录或注册新账号，卸载重装不影响封禁效力。登录时将提示「该账户已被封禁」并显示解除时间；永久封禁显示为永久。你对处置有异议的，可通过软件内的申诉入口或第二十条邮箱申诉：永久封禁可申诉 2 次、其他封禁可申诉 3 次，超过次数不再受理；维护者复核后答复，申诉成立的解除封禁。
2. 你的终止。你可随时停止使用本软件：退出登录、通过安全中心注销账号（见第七条第 7 款），或卸载本软件终止本协议；卸载后本地数据的处理见第七条第 1 款。
3. 服务终止。维护者如决定终止账号、积分、兑换或论坛等在线服务，将提前通过应用内公告、官方网站或官方仓库发布通知，并为你预留合理的数据处理期限。在线服务终止后，维护者将发布不依赖账号的版本供你继续使用本软件的本地核心功能；服务器侧账号数据将按照第七条与通知说明的期限删除。维护者停止维护或发布新版，不影响你已安装的受支持版本在本地的继续使用，但维护者无义务为已停止服务的版本提供支持。
4. 存续条款。本协议终止后，第五条、第七条中与已发生的数据处理有关的约定、第九条第 7 款、第十四条、第十五条、第十六条、第十八条继续有效。

十八、法律适用与争议解决

1. 本协议的订立、效力、解释及履行，在不违反适用法律强制性规定的前提下，适用中华人民共和国法律。
2. 因本协议或本软件产生的争议，双方应先通过第二十条联系方式友好协商；协商不成的，由依法具有管辖权的人民法院处理。

十九、其他

1. 本协议任一条款被认定无效，不影响其他条款的效力。
2. 本协议标题仅为阅读方便，不影响条款解释。
3. 《QFClash 应用使用详细报告》是本软件的使用说明文件，积分规则、论坛审核规则等公示文件是本协议相关事项的具体说明；前述文件对功能与规则细节的描述如与本协议冲突，以本协议为准。
4. 本协议未约定事项，依适用法律法规及相关开源许可证处理。本协议任何内容均不影响用户依法享有的权利，也不限制开源许可证已明确授予用户的权利。

二十、官方信息与联系方式

- 源代码获取：本软件基于开源项目，源代码可通过官网联系邮箱索取。
- 官方网站：以本软件"关于"页公布的地址为准
- 联系方式（谷歌邮箱）：a718983610@gmail.com（亦为封禁、禁言等处置的申诉邮箱）
- 运营主体：QFClash 由个人维护者运营；法律通知与隐私相关问题，请通过上述邮箱联系
- 当前协议版本：3.0
- 应用版本与使用报告版本：见"关于"页



版本与生效说明：本协议版本号为 3.0，随 QFClash 1.0.0 发布之日起生效，并自生效之日起取代协议 2.0 版。老用户从旧版本升级至 1.0.0 后，首次打开应用时将重新展示本协议全文，须重新勾选同意后方可继续使用（见第三条第 3 款）。
''';
