class QfConfig {
  static const String repository = 'a718983610-sys/FlClash';
  static const String manifestUrl =
      'https://raw.githubusercontent.com/$repository/main/qfclash-release.json';
  static const String fallbackServerBaseUrl =
      'https://qfclash-account.a718983610.workers.dev';
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
}
