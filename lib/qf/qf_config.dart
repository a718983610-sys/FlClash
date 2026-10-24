class QfConfig {
  static const String repository = 'a718983610-sys/FlClash';
  static const String manifestUrl =
      'https://raw.githubusercontent.com/$repository/main/qfclash-release.json';
  static const String fallbackServerBaseUrl =
      'https://qfclash-account.a718983610.workers.dev';
  // Google OAuth client IDs are public identifiers (they ship in every
  // client and in the public release manifest), not secrets. Built in so
  // Google sign-in works on a cold start with no manifest ever fetched;
  // a fetched manifest still overrides them.
  static const String builtinGoogleWebClientId =
      '340614194006-7a7anda3p473qjlhr67k6hn3o6aaqu9o.apps.googleusercontent.com';
  static const String builtinGoogleAndroidClientId =
      '340614194006-80vi66ee45a447nvudpqc93vp7u0mo31.apps.googleusercontent.com';
  static const String builtinGoogleWindowsClientId =
      '340614194006-m77lgrsv2ne7dn921lkascgg3ehvvvjf.apps.googleusercontent.com';
  static const String agreementVersion = '3.0';
  static const String contactEmail = 'a718983610@gmail.com';
}

String? qfUsernameError(String input) {
  final value = input.trim();
  if (value.isEmpty) return '请输入账户 ID';
  if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(value)) {
    return '账户 ID 只能使用英文字母与数字';
  }
  if (value.length < 8) return '账户 ID 至少需要 8 位';
  if (!RegExp(r'[A-Za-z]').hasMatch(value)) {
    return '账户 ID 必须包含英文字母';
  }
  return null;
}

class QfCopy {
  static const String usernameRuleHint = '账户 ID 至少 8 位，必须包含英文字母，只能使用英文字母与数字。';
  static const String usernameTaken = '该账户ID已被注册。';
  static const String loginBenefit = '登录状态不受限制：连接时长不限，全部功能完整开放，连接使用可累计积分。';
  static const String guestNotice =
      '免登录即进入访客模式：每日可使用 2 小时，仅开放订阅导入、连接、规则、'
      '全局模式与节点切换等基础功能，不提供积分累计与兑换服务。';
  static const String guestIntroTitle = '以访客模式继续';
  static const String quotaTitle = '今日免费额度已用完';
  static const String quotaBody =
      '您当日的免费使用 2 小时额度已用完。登录状态不受限制：连接时长不限、'
      '全部功能完整开放，还可累计积分，兑换美元奖励。';
  static const String guestRestricted = '访客模式下此功能暂不可用。登录状态不受限制，登录后即可使用全部功能。';
  static const String registerCodeHint = '验证通过后设置登录密码（需填写两次确认）。';
  static const String passwordMismatch = '两次输入的密码不一致，请重新输入。';
  static const String maintenanceTitle = '系统维护中';
  static const String maintenanceBody = '系统维护中，请稍后再试。';
  static const String forceUpdateTitle = '发现重大更新';
  static const String forceUpdateBody = 'QFClash 新大版本已发布，本次为大版本更新，必须更新后才能继续使用。';
  static const String retiredTitle = '该版本已停止服务';
  static const String retiredBody = '您当前使用的版本已停止服务，无法继续使用，请更新到最新版本。';
  static const String minorUpdateTitle = '发现新版本';
  static const String updateNow = '立即更新';
  static const String feedbackTitle = '意见反馈';
  static const String feedbackHint = '您的意见将直接发送至维护团队，感谢您的反馈。';
  static const String feedbackSuccess = '提交成功，感谢您的反馈。';
  static const String forumRewardExplain =
      '单篇帖子获赞达到 1000 次后可申请奖励 5 积分。奖励经人工审核后发放至您的积分账户，每篇帖子限申请一次。';
  static const String forumRewardPending = '审核中';
  static const String forumRewardApproved = '已发放';
  static const String forumRewardRejected = '已驳回';
  static const String supportBotName = '智能客服';
  static const String supportAgentName = '人工客服';
  static const String supportBanner =
      '本会话为智能客服自动回复，内容不进行端到端加密。'
      '为保障您的权益，请勿在会话中发送密码、验证码等敏感信息。';
  static const String supportAutoReplyTag = '自动回复';
  static const String supportHandoffNotice = '已为您转接人工客服。人工客服的回复将显示在本会话中。';
  static const String supportHandoffDone = '已转接人工客服，您可以继续在本会话中留言。';
  static const String supportNotThis = '不是这个';
  static const String supportDeskTitle = '客服会话';
  static const String campCreate = '创建营地';
  static const String campMyCamps = '我的营地';
  static const String campNameLabel = '营地名称';
  static const String campDescriptionLabel = '营地简介';
  static const String campCreateRules =
      '营地提交后将经审核，审核通过后正式上线。营地名称全网唯一，'
      '同一账号最多创建 3 个营地。';
  static const String campCreateSubmit = '提交创建';
  static const String campCreateActive = '创建成功，营地已正式上线。';
  static const String campCreatePending = '已提交，请等待审核。审核通过后，营地将正式上线。';
  static const String campCreateRejected = '未通过审核';
  static const String campNameTaken = '该营地名称已被使用。';
  static const String campStatusPending = '待审核';
  static const String campStatusActive = '已上线';
  static const String campStatusRejected = '未通过';
  static const String campStatusClosed = '已关闭';
  static const String campCloseReasonPrefix = '关闭原因：';
  static const String campMemberCountSuffix = ' 位成员';
  static const String campCreatorLabel = '创建者';
  static const String campEdit = '编辑营地';
  static const String campEditSubmit = '保存修改';
  static const String campEditSubmitted = '修改已提交，审核通过后生效。';
  static const String campEditPendingNote = '有修改正在审核中，审核通过后生效。';
  static const String campEmptyMine = '暂无营地';
  static const String forumLoadFailed = '加载失败，请检查网络后重试。';
  static const String forumRewardStatusFailed = '奖励状态加载失败';
  static const String campFormRequired = '营地名称与简介不能为空。';
  static const String campResubmit = '修改并重新提交';
  static const String campResubmitSubmit = '重新提交审核';
  static const String campResubmitted = '已重新提交，请等待审核。审核通过后，营地将正式上线。';
  static const String campDelete = '删除营地';
  static const String campDeleteConfirmTitle = '删除营地';
  static const String campDeleteConfirmBody = '删除后该营地将无法恢复，确定要删除吗？';
  static const String campDeleted = '营地已删除。';
  static const String appealStatusTitle = '查询申诉结果';
  static const String appealStatusEmpty = '暂未查询到申诉记录。如您已提交申诉，请核对账户与密码后重新查询。';
  static const String appealStatusPending = '审核中';
  static const String appealStatusApproved = '申诉已通过';
  static const String appealStatusRejected = '申诉未通过';
  static const String appealPasskeyVerify = '使用通行密钥查询';
  static const String vaultUnlockTitle = '解锁保险库';
  static const String vaultUnlockedState = '保险库已解锁，设置同步已开启。';
  static const String vaultLockedState = '保险库尚未解锁。解锁后，订阅备份与设置将自动同步。';
  static const String vaultClearSettings = '清除云端设置备份';
  static const String vaultClearSettingsConfirm =
      '清除后云端设置备份将被删除，无法恢复；本机设置不受影响。确定要清除吗？';
  static const String vaultSettingsCleared = '云端设置备份已清除。';
  static const String deviceTrusted = '已信任';
  static const String deviceUntrusted = '未信任';
  static const String deviceUntrust = '取消信任';
  static const String deviceUntrustConfirm =
      '取消信任后，该设备将被退出登录，下次登录时需要重新验证。确定要取消信任吗？';
  static const String deviceUntrustedDone = '已取消对这台设备的信任。';
  static const String chatDecryptFailed = '这条消息暂时无法解密。';
  static const String chatRecoverKey = '恢复聊天密钥';
  static const String orderCancel = '取消订单';
  static const String orderCancelConfirm = '取消后积分将退回您的账户，确定要取消该订单吗？';
  static const String orderCancelledDone = '订单已取消，积分已退回。';
  static const String orderChangeAddress = '修改地址';
  static const String orderChangeAddressDone = '收款地址已修改。';
  static const String forumAnnouncementForbidden = '公告板块仅官方发布。';
  static const String networkAccountUnreachable =
      '当前网络无法连接账户服务器。您可以先以访客模式使用，或检查网络后重试。';
  static const String networkAccountNeedsProxy =
      '当前网络无法连接账户服务器（当前网络可能需要代理）。您可以先以访客模式使用，或开启代理后重试。';
  static const String networkGuestUnreachable = '当前网络无法连接服务器，请检查网络后重试。';
  static const String egressChecking = '正在检测网络连通性…';
  static const String egressOk = '已连接，网络正常。';
  static const String egressNodeUnreachable = '已连接，但当前节点无法访问网络，请切换节点后重试。';
  static const String egressTakeoverFailed =
      '系统代理没有设置成功，其他应用的流量不会经过代理。请点击重试；若仍失败，请检查安全软件是否拦截了系统代理设置。';
  static const String egressHandshakeFailed =
      '节点握手失败，请检查电脑系统时间是否准确（与标准时间误差超过半分钟时，节点会拒绝连接），校准后重新连接再试。';
  static const String egressRetryCheck = '重新检测';
  static const String egressRetryProxy = '重试设置';
  static const String storageSaveFailed = '无法安全保存登录状态，请重试。';
  static const String avatarUpdateFailed = '头像更新失败，请重试。';
  static const String qrCameraUnsupported = '当前设备不支持相机扫码，请导入二维码图片。';
  static const String qrNoCodeFound = '图片中没有识别到有效的二维码';
  static const String googleNotConfiguredHint = '谷歌登录尚未完成配置，请改用邮箱或账户 ID 登录。';
  static const String googleConfigNetworkHint =
      '暂时无法连接谷歌登录服务，请检查网络后重试，或改用邮箱或账户 ID 登录。';
  static const String actionFailedRetry = '操作没有完成，请检查网络后重试；如果连续失败，请稍后再试。';
  static const String attachmentsTitle = '我的附件';
  static const String attachmentsEmpty = '暂无附件';
  static const String attachmentsDeleteHint = '删除后文件将进入 7 天待删除期，期满后彻底清除。';
}
