class User
  include MongoMapper::Document

  key :name, String
  key :email, String
  key :logued, Boolean
  key :s_token, String
  key :fb_id, String
  key :fb_login_token, String
  key :fb_access_token, String
  key :fb_expires_at, Integer
  key :points, Integer, :default => 0
  key :total_points, Integer, :default => 0
  key :actions_count, Integer, :default => 0
  key :buys_count, Integer, :default => 0
  key :likes_count, Integer, :default => 0
  key :shares_count, Integer, :default => 0
  key :pages_visited, Integer, :default => 1
  key :logins, Integer, :default => 1
  key :visited_at, Time
  key :last_action_at, Time, :default => Time.now
  key :redeemed_rewards, Hash
  key :reward_hits, Hash
  timestamps!

  belongs_to :shop
  many :coupons


  def self.verify(shop_id, user_id, s_token)
    return User.first({'shop_id' => shop_id, 'id' => user_id, 's_token' => s_token})
  end

  def redeem_daily_visit_point
    self.points += 1
    self.total_points += 1
    self.pages_visited += 1
    self.logins += 1
    self.visited_at = Time.now
    self.save!
  end

  def add_init_rewards(shop)
    shop.rewards.each { |r| self.reward_hits[r.id.to_s] = 0 if r.init }
  end

  def redeem_reward_points(reward)
    if self.reward_hits[reward.id.to_s].nil?
      self.reward_hits[reward.id.to_s] = 1
    else
      self.reward_hits[reward.id.to_s] += 1
    end
    redeemed = false
    add_points = 0
    add_msg = ''
    if self.redeemed_rewards[reward.id.to_s].nil?
      # if he didnt get it yet, and has enought hits, he gets it
      if self.reward_hits[reward.id.to_s] >= reward.redeem_hits[0]
        self.redeemed_rewards[reward.id.to_s] = 1
        redeemed = true
      else
        pts_left = reward.redeem_hits[0] - self.reward_hits[reward.id.to_s]
        add_msg = 'Just ' + pts_left.to_s + ' more ' + reward.name + ' to get your points!'
      end
    elsif reward.repeatable
      # if he got it already, checks if it's repeatable
      if self.reward_hits[reward.id.to_s] >= reward.redeem_hits[0]
        # if it has enought hits, he get's the points and reset the hit count
        self.reward_hits[reward.id.to_s] = 0
        self.redeemed_rewards[reward.id.to_s] += 1
        redeemed = true
      else
        pts_left = reward.redeem_hits[0] - self.reward_hits[reward.id.to_s]
        add_msg = 'Just ' + pts_left.to_s + ' more ' + reward.name + ' to get your points!'
      end
    elsif reward.redeem_hits.size > self.redeemed_rewards[reward.id.to_s]
      # if not repeatable but there are more levels...
      if self.reward_hits[reward.id.to_s] >= reward.redeem_hits[self.redeemed_rewards[reward.id.to_s]]
        self.redeemed_rewards[reward.id.to_s] += 1
        redeemed = true
      else
        pts_left = reward.redeem_hits[self.redeemed_rewards[reward.id.to_s]] - self.reward_hits[reward.id.to_s]
        add_msg = 'Just ' + pts_left.to_s + ' more ' + reward.name + ' to get your points!'
      end
    else
      # already got the max level
      self.reward_hits[reward.id.to_s] -= 1
    end

    self.actions_count += 1
    if reward.name == "likes"
      self.likes_count += 1
    elsif reward.name == "sharing"
      self.shares_count += 1
    elsif reward.name.include? "buy"
      self.buys_count += 1
    end

    if redeemed
      if reward.repeatable
        adding_points = reward.add_points[0]
      else
        adding_points = reward.add_points[self.redeemed_rewards[reward.id.to_s]-1]
      end
      self.total_points += adding_points
      self.points += adding_points
      add_points = adding_points
      add_msg = reward.add_msg
    end

    self.last_action_at = Time.now

    if self.save!
      if redeemed
        reward.redeemed += 1
        reward.save!
      end
    end

    return add_points, add_msg
  end


  def self.count_actions(shop_id, opts={})
    opts[:out] = "map_reduce_results"
    map = <<-MAP
              function() {
                if (this.shop_id == "#{shop_id}") {
                  emit( this.shop_id, {
                    shares: this.shares_count,
                    likes: this.likes_count,
                    buys: this.buys_count
                  });
                }
              }
            MAP
    reduce = <<-REDUCE
                function(k, v) {
                  var total_users = 0;
                  var shares = 0;
                  var likes = 0;
                  var buys = 0;
                  for (var i in v) {
                    total_users += 1;
                    shares += v[i]["shares"];
                    likes += v[i]["likes"];
                    buys += v[i]["buys"];
                  }
                  return { shares: shares, likes: likes, buys: buys,
                    total_users: total_users };
                }
              REDUCE

    data = nil
    User.collection.map_reduce(map, reduce, opts).find().each do |v|
      data = { shares: v["value"]["shares"],
              likes: v["value"]["likes"],
              buys: v["value"]["buys"],
              users_count: v["value"]["total_users"] }
    end
    data
  end


  def self.count_redeemed(shop_id, opts={})
    opts[:out] = "map_reduce_results"
    map = <<-MAP
              function() {
                if (this.shop_id == "#{shop_id}") {
                  for (var c in this.coupons) {
                    emit( this.coupons[c].description, {
                      count: 1,
                      user_id: this._id.str
                    } );
                  }
                }
              }
            MAP
    reduce = <<-REDUCE
                function(k, v) {
                  var count = 0;
                  var total_users = {};
                  for (var i in v) {
                    count += 1;
                    total_users[v[i]["user_id"]] = 1;
                  }
                  return { count: count, total_users: total_users };
                }
              REDUCE

    data = {}
    User.collection.map_reduce(map, reduce, opts).find().each do |v|
      data[v["_id"]] = { amount: v["value"]["count"],
                        total_users: v["value"]["total_users"]
                      }
    end
    data
  end


  def self.most_redeems_week_day(shop_id, opts={})
    opts[:out] = "map_reduce_results"
    map = <<-MAP
              function() {
                if (this.shop_id == "#{shop_id}") {
                  for (var c in this.coupons) {
                    emit( this.coupons[c].created_at.getDay(), {
                      count: 1
                    } );
                  }
                }
              }
            MAP
    reduce = <<-REDUCE
                function(k, v) {
                  var count = 0;
                  for (var i in v) {
                    count += 1;
                  }
                  return { count: count };
                }
              REDUCE

    data = {}
    User.collection.map_reduce(map, reduce, opts).find().each do |v|
      data[v["_id"]] = v["value"]["count"]
    end
    data
  end


  def self.most_redeems_week_number(shop_id, opts={})
    opts[:out] = "map_reduce_results"
    map = <<-MAP
              function() {
                if (this.shop_id == "#{shop_id}") {
                  for (var c in this.coupons) {
                    var date = this.coupons[c].created_at;
                    var dowOffset = 0;
                    var newYear = new Date(date.getFullYear(),0,1);
                    var day = newYear.getDay() - dowOffset;
                    day = (day >= 0 ? day : day + 7);
                    var daynum = Math.floor((date.getTime() - newYear.getTime() -
                    (date.getTimezoneOffset()-newYear.getTimezoneOffset())*60000)/86400000) + 1;
                    var weeknum;
                    //if the year starts before the middle of a week
                    if(day < 4) {
                      weeknum = Math.floor((daynum+day-1)/7) + 1;
                      if(weeknum > 52) {
                        nYear = new Date(this.getFullYear() + 1,0,1);
                        nday = nYear.getDay() - dowOffset;
                        nday = nday >= 0 ? nday : nday + 7;
                        weeknum = nday < 4 ? 1 : 53;
                      }
                    }
                    else {
                      weeknum = Math.floor((daynum+day-1)/7);
                    }
                    emit( weeknum, {
                      count: 1
                    } );
                  }
                }
              }
            MAP
    reduce = <<-REDUCE
                function(k, v) {
                  var count = 0;
                  for (var i in v) {
                    count += 1;
                  }
                  return { count: count };
                }
              REDUCE

    data = {}
    User.collection.map_reduce(map, reduce, opts).find().each do |v|
      data[v["_id"]] = v["value"]["count"]
    end
    data
  end


  def self.points_histogram(shop_id, opts={})
    opts[:out] = "map_reduce_results"
    map = <<-MAP
              function() {
                if (this.shop_id == "#{shop_id}") {
                  var range = Math.floor(this.points / 30);
                  emit( range, { count: 1 } );
                }
              }
            MAP
    reduce = <<-REDUCE
                function(k, v) {
                  var count = 0;
                  for (var i in v) {
                    count += 1;
                  }
                  return { count: count };
                }
              REDUCE

    data = []
    User.collection.map_reduce(map, reduce, opts).find().each do |v|
      data[v["_id"]] = v["value"]["count"]
    end
    data
  end

end