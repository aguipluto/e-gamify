class Shop
  include MongoMapper::Document

  key :name, String
  key :premium, Boolean, :default => false
  key :uri, String
  key :language, String, :default => 'EN'
  key :widgets, Array
  # add timed rewards...
  timestamps!

  belongs_to :site_owner
  many :users
  many :rewards

end