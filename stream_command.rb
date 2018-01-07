# -*- coding: utf-8 -*-

module Plugin::StreamCommand
  RateLimit = Struct.new(:count, :minutes)
  RequestLimit = Struct.new(:expires, :count, :limit)

  # User毎のレートリミット残数
  @limits = {}
  # コマンド毎のレートリミット設定
  @rate_limits = {}
  # 管理者専用コマンドの設定
  @private_commands = Set[]
  # 別名の設定
  @aliases = {}

  class << self
    attr_accessor :limits, :rate_limits, :private_commands, :aliases

    # ログを出力する。
    # @param [String] text 出力する内容
    def put_log(*text)
      puts [Time.now, text].join('|')
    end
  end
end

Plugin.create(:stream_command) do

  # コマンドの別名を定義する。
  # original_name : 別名を設定したいコマンドのslug
  # alias_name    : 新しい別名のslug
  defdsl :stream_command_alias do |original_name, alias_name|
    Plugin::StreamCommand.aliases[alias_name] = original_name
  end

  # コマンドを定義する。
  # slug    : コマンドのslug
  # options :
  #   private          : コマンドを管理者専用にする。既定では誰でも実行できる。
  #   rate_limit       : rate_limit_reset分以内に何回まで実行を許可するか、レートリミットを設定する。rate_limit_resetも設定すること。
  #   rate_limit_reset : rate_limitのカウントをリセットするまでの時間(分)を設定する。rate_limitも設定すること。
  # &exec   : コマンドの実行内容
  defdsl :stream_command do |slug, **options, &exec|
    # :private
    if options[:private]
      Plugin::StreamCommand.private_commands << slug
    end
    # :rate_limit, :rate_limit_reset
    if options.values_at(:rate_limit, :rate_limit_reset).none?(&:nil?)
      Plugin::StreamCommand::rate_limits[slug] = Plugin::StreamCommand::RateLimit.new(options[:rate_limit], options[:rate_limit_reset])
    end
    # register
    add_event(:"stream_command_#{slug}", &exec)
  end

  on_appear do |msgs|
    reply_pattern = /^@#{Service.primary.idname} ([a-z_]+) (.+)$/
    msgs.select { |msg| msg.created > defined_time  }
        .select { |msg| msg.body =~ reply_pattern }
        .each { |msg|
          msg.body =~ reply_pattern
          cmd = $1.to_sym
          cmd = Plugin::StreamCommand.aliases[cmd] if Plugin::StreamCommand.aliases.has_key? cmd
          args = $2.split

          if authorized?(cmd, msg) && !rate_limit_exceeded?(cmd, msg)
            Plugin::StreamCommand.put_log cmd, "@#{msg.user.idname} -- #{args}"
            Plugin.call(:"stream_command_#{cmd}", msg, *args)
          end
        }
  end

  # コマンドの実行が許可されているか確認する。
  # @params [Symbol] slug コマンドのslug
  # @params [Message] msg メッセージ
  def authorized?(slug, msg)
    if Plugin::StreamCommand.private_commands.include?(slug) && !msg.user.me?
      Plugin::StreamCommand.put_log 'WARN', 'Unauthorized operation', "#{slug}|@#{msg.user.idname}"
      compose(Service.primary, msg, body: "@#{msg.user.idname} このコマンドは本人のみ使用可能です。 (#{Time.now})")
      false
    else
      true
    end
  end

  # リクエスト上限を取得する。この時、呼び出し回数がインクリメントされる。
  # また、既存のリクエスト上限のオブジェクトの期限が失効している場合は新規に作り直す。
  # @params [String] id ScreenName
  # @params [Plugin::StreamCommand::RateLimit] rate_limit レートリミット設定
  def find_limit(id, slug, rate_limit)
    limits = Plugin::StreamCommand.limits[id] || {}
    limit = limits[slug]
    if limit.nil? || limit.expires < DateTime.now
      limit = Plugin::StreamCommand::RequestLimit.new(DateTime.now + Rational(rate_limit.minutes, 24 * 60), 0, rate_limit.count)
    end
    if limit.count < limit.limit + 1
      limit.count += 1
    end
    limits[slug] = limit
    Plugin::StreamCommand.limits[id] = limits

    limit
  end

  # レートリミットに引っかかっているかチェックする。
  # @params [Symbol] slug コマンドのslug
  # @params [Message] msg メッセージ
  def rate_limit_exceeded?(slug, msg)
    if Plugin::StreamCommand.rate_limits.has_key?(slug)
      rate_limit = Plugin::StreamCommand.rate_limits[slug]
      limit = find_limit(msg.user.idname, slug, rate_limit)
      if limit.count > limit.limit
        Plugin::StreamCommand.put_log 'RateLimit', slug, msg.user.idname, "#{limit.count}/#{limit.limit}", limit.expires
        compose(Service.primary, msg, body: "@#{msg.user.idname} 一時的にリクエストを受付できません。(Limit: #{limit.count}/#{limit.limit}, Expires: #{limit.expires}, Now: #{Time.now})")
        true
      end
    end
  end
end

