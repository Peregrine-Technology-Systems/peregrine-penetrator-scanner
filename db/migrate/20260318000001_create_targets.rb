class CreateTargets < ActiveRecord::Migration[7.1]
  def change
    create_table :targets, id: false do |t|
      t.string :id, limit: 36, primary_key: true
      t.string :name, null: false
      t.text :urls, null: false, default: "[]"
      t.string :auth_type, default: "none"
      t.text :auth_config
      t.text :scope_config
      t.text :brand_config
      t.boolean :active, default: true

      t.timestamps
    end
  end
end
