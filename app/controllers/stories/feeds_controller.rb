module Stories
  class FeedsController < ApplicationController
    respond_to :json

    before_action :current_user_by_token, only: [:show]

    def show
      @page = (params[:page] || 1).to_i
      # This most recent test has concluded with a winner. Preserved as a comment awaiting next test
      # @comments_variant = field_test(:comments_to_display_20240129, participant: @user)
      @comments_variant = "more_inclusive_recent_good_comments"

      @stories = assign_feed_stories

      add_pinned_article
    end

    private

    def add_pinned_article
      return if params[:timeframe].present?

      pinned_article = PinnedArticle.get
      return if pinned_article.nil? || @stories.detect { |story| story.id == pinned_article.id }

      @stories.prepend(pinned_article.decorate)
    end

    def assign_feed_stories
      params[:type_of] = "discover" if params[:type_of].blank?
      stories = if params[:timeframe].in?(Timeframe::FILTER_TIMEFRAMES)
                  timeframe_feed
                elsif params[:type_of] == "following" && user_signed_in? && params[:timeframe] == Timeframe::LATEST_TIMEFRAME
                  latest_following_feed
                elsif params[:type_of] == "following" && user_signed_in?
                  relevant_following_feed
                elsif params[:timeframe] == Timeframe::LATEST_TIMEFRAME
                  latest_feed
                elsif user_signed_in?
                  signed_in_base_feed
                else
                  signed_out_base_feed
                end

      ArticleDecorator.decorate_collection(stories)
    end

    def signed_in_base_feed
      feed_strategy = params[:mode] || Settings::UserExperience.feed_strategy
      feed = if feed_strategy == "basic" && params[:type_of] != "following"
               Articles::Feeds::Basic.new(user: current_user, page: @page, tag: params[:tag])
             elsif feed_strategy == "configured" && params[:type_of] != "following"

                @feed_config = if params[:item]
                                 FeedConfig.find_by(id: params[:item]) || FeedConfig.order("feed_success_score DESC").limit(rand(15)).sample || FeedConfig.first_or_create
                               elsif rand(20) == 0 # 5% of the time, we'll just pick a random feed config
                                 FeedConfig.where("feed_impressions_count < 100").order("RANDOM()").limit(1).first || FeedConfig.order("feed_success_score DESC").limit(rand(15)).sample || FeedConfig.first_or_create
                               else
                                 FeedConfig.order("feed_success_score DESC").limit(rand(15)).sample || FeedConfig.first_or_create
                               end
               Articles::Feeds::Custom.new(user: current_user, page: @page, tag: params[:tag], feed_config: @feed_config)
             else
               Articles::Feeds.feed_for(
                 user: current_user,
                 controller: self,
                 page: @page,
                 tag: params[:tag],
                 number_of_articles: 35,
                 type_of: params[:type_of] || "discover",
               )
             end
      # Hey, why the to_a you say?  Because the
      # LargeForemExperimental has already done this.  But the
      # weighted strategy has not.  I also don't want to alter the
      # weighted query implementation as it returns a lovely
      # ActiveRecord::Relation.  So this is a compromise.

      feed.more_comments_minimal_weight_randomized(comments_variant: @comments_variant)
    end

    def signed_out_base_feed
      feed = if Settings::UserExperience.feed_strategy == "basic"
               Articles::Feeds::Basic.new(user: nil, page: @page, tag: params[:tag])
             else
               Articles::Feeds.feed_for(
                 user: current_user,
                 controller: self,
                 page: @page,
                 tag: params[:tag],
                 number_of_articles: 25,
                 type_of: "discover",
               )
             end
      Datadog::Tracing.trace("feed.query",
                             span_type: "db",
                             resource: "#{self.class}.#{__method__}",
                             tags: { feed_class: feed.class.to_s.dasherize }) do
        # Hey, why the to_a you say?  Because the
        # LargeForemExperimental has already done this.  But the
        # weighted strategy has not.  I also don't want to alter the
        # weighted query implementation as it returns a lovely
        # ActiveRecord::Relation.  So this is a compromise.
        feed.default_home_feed(user_signed_in: false).to_a
      end
    end

    def timeframe_feed
      Articles::Feeds::Timeframe.call(params[:timeframe], tag: params[:tag], page: @page)
    end

    def latest_feed
      Articles::Feeds::Latest.call(tag: params[:tag], page: @page)
    end

    def latest_following_feed
      activity = current_user.user_activity
      user_ids = activity&.alltime_users || current_user.cached_following_users_ids
      organization_ids = activity&.alltime_organizations || current_user.cached_following_organizations_ids
      left_scope  = Article.published.from_subforem.where(user_id: user_ids)
      right_scope = Article.published.from_subforem.where(organization_id: organization_ids)      

      @articles = left_scope
        .or(right_scope)
        .where("score > -10")
        .order("published_at DESC")
        .page(@page)
        .per(25)
    end

    def relevant_following_feed
      activity = current_user.user_activity
      user_ids = activity&.alltime_users || current_user.cached_following_users_ids
      organization_ids = activity&.alltime_organizations || current_user.cached_following_organizations_ids
      left_scope  = Article.published.from_subforem.where(user_id: user_ids)
      right_scope = Article.published.from_subforem.where(organization_id: organization_ids)
      
      @articles = left_scope
        .or(right_scope)
        .where("score > -10")
        .order("hotness_score DESC")
        .page(@page)
        .per(25)
    end
  end
end
