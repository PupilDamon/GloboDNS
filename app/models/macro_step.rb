class MacroStep < ActiveRecord::Base

  @@valid_actions = %w{ create update remove }
  cattr_reader :valid_actions
  
  validates_presence_of :macro_id
  validates_presence_of :content, :if => :content_required?
  validates_inclusion_of :action, :in => self.valid_actions
  validates_inclusion_of :record_type, :in => Macro.record_types

  belongs_to :macro

  acts_as_list :scope => :macro

  # Convert this step into a valid #Record
  def build( domain = nil )
    record_class = self.record_type.constantize

    # make a clean copy of ourself
    attrs = self.attributes.dup
    attrs.delete_if { |k,_| !record_class.columns.map(&:name).include?( k ) }
    attrs.delete(:id)

    # parse each attribute for %ZONE%
    unless domain.nil?
      attrs.keys.each do |k|
        attrs[k] = attrs[k].gsub( '%ZONE%', domain.name ) if attrs[k].is_a?( String )
      end
    end

    record_class.new( attrs )
  end
  
  # Here we perform some magic to inherit the validations from our parent
  # #Record (record_type)
  def validate
    return if self.record_type.blank? || !self.errors.on(:record_type).blank?

    record = build

    record.errors.each do |k,v|
      next if k == "domain_id" || k == "ttl"

      self.errors.add( k, v )
    end unless record.valid?
  end

  def content_required?
    self.action != 'remove'
  end
  
end