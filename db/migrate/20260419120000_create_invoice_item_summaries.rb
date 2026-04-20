class CreateInvoiceItemSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_item_summaries do |t|
      t.string :host, null: false
      t.string :ksef_number, null: false
      t.string :summary, null: false
      t.string :source, null: false

      t.timestamps
    end

    add_index :invoice_item_summaries, [ :host, :ksef_number ], unique: true
  end
end
