require 'parser'
require 'cql'

class SequencesController < ApplicationController
  before_action :authenticate_user!
  before_action :find_workspace, only: [:new, :index, :create]
  before_action :find_workspaces, only: [:new]
  before_action :pager_params, only: [:index]
  before_action :find_sequence, only: [:show, :download]

  def index
    if !@before.nil?
      @sequences = Sequence.where(workspace_id: @current_workspace.id)
                   .before(@before).limit(@limit).reverse.to_a.reverse
    elsif !@after.nil?
      @sequences = Sequence.where(workspace_id: @current_workspace.id)
                   .after(@after).limit(@limit).to_a
    else
      @sequences = Sequence.where(workspace_id: @current_workspace.id)
                   .first(@limit).to_a
    end

    unless @sequences.empty?
      unless (Sequence.where(workspace_id: @current_workspace.id)
               .before(@sequences.first.name).limit(1).to_a.empty?)
        @previous_url = "#{workspace_sequences_url}?" \
                        "limit=#{@limit}&" \
                        "before=#{CGI.escape(@sequences.first.name)}"
      end
      unless (Sequence.where(workspace_id: @current_workspace.id)
               .after(@sequences.last.name).limit(1).to_a.empty?)
        @next_url = "#{workspace_sequences_url}?" \
                    "limit=#{@limit}&" \
                    "after=#{CGI.escape(@sequences.last.name)}"
      end
    end
  end

  def new
    @formats = {
      gff: "Generic Feature Format (gff)",
      gtf: "General Transfer Format (gtf)",
      fasta: "FASTA Format (fasta)"
    }

    @workspaces
  end

  def show
  end

  def create
    format = params[:format].downcase

    if respond_to? "create_#{format}", true
      send "create_#{format}"
    else
      fail "Unsupport format."
    end

    redirect_to workspace_sequences_url
  end

  def download
    respond_to do |format|
      format.fasta do
        if @sequence.description.nil?
          data = ">#{@sequence.name}\n#{@sequence.sequence}\n"
        else
          data = ">#{@sequence.name} #{@sequence.description}\n#{@sequence.sequence}\n"
        end
        send_data data, filename: "#{@sequence.name}.fasta"
      end
    end
  end

  private

  def create_gff
    slice_size = 1000
    records = []

    Parser::Gff.parse params[:file].path do |record|
      if record.attributes.id.nil?
        record.attributes.id = [
          record.type,
          record.start,
          record.end,
          record.seqid
        ].join "."
      end
      records << record
    end

    records.each_slice(slice_size) do |slice|
      cmd = ['BEGIN BATCH ']
      slice.each do |record|
        cmd << %(
          INSERT INTO #{Location.table_name}
            (#{Location.column_names.join(',')})
          VALUES (
            #{CQL.quote(@current_workspace.id.to_s)},
            #{CQL.quote(record.seqid)},
            #{CQL.quote(record.type)},
            #{CQL.quote(record.start)},
            #{CQL.quote(record.end)},
            #{CQL.quote(record.source)},
            #{CQL.quote(record.attributes.id)},
            #{CQL.quote(record.score)},
            #{CQL.quote(record.strand)},
            #{CQL.quote(record.phase)}
          )
        ;).squish

        cmd << %(
          INSERT INTO #{Sequence.table_name}
            (workspace_id, name, type)
          VALUES (
            #{CQL.quote(@current_workspace.id.to_s)},
            #{CQL.quote(record.attributes.id)},
            #{CQL.quote(record.type)}
          )
        ;).squish

        cmd << %(
          INSERT INTO #{Sequence.table_name}
            (workspace_id, name, type)
          VALUES (
            #{CQL.quote(@current_workspace.id.to_s)},
            #{CQL.quote(record.seqid)},
            'chromosome'
          )
        ;).squish

        unless record.attributes.parent.nil?
          cmd << %(
            UPDATE #{Sequence.table_name}
            SET parents = parents + {#{CQL.quote(record.attributes.parent)}}
            WHERE workspace_id = '#{@current_workspace.id}'
            AND name = #{Cequel::Type.quote(record.attributes.id)}
          ;).squish

          cmd << %(
            UPDATE #{Sequence.table_name}
            SET children = children + {#{CQL.quote(record.attributes.id)}}
            WHERE workspace_id = #{CQL.quote(@current_workspace.id.to_s)}
            AND name = #{CQL.quote(record.attributes.parent)}
          ;).squish
        end
      end
      cmd << "APPLY BATCH;"
      Sequence.connection.execute(cmd.join)
    end
  end

  def create_gtf
  end

  def create_fasta
    slice_size = 1000
    records = []

    Parser::Fasta.parse params[:file].path do |record|
      records << record
    end

    records.each_slice(slice_size) do |slice|
      cmd = ['BEGIN BATCH ']
      slice.each do |record|
        cmd << %(
          INSERT INTO #{Sequence.table_name}
            (workspace_id, name, description, sequence)
          VALUES (
            #{CQL.quote(@current_workspace.id.to_s)},
            #{CQL.quote(record.name)},
            #{CQL.quote(record.description)},
            #{CQL.quote(record.sequence)}
          )
        ;).squish
      end
      cmd << "APPLY BATCH;"
      Sequence.connection.execute(cmd.join)
    end
  end

  def create_expr
  end

  def find_workspace
    workspace = Workspace.where(id: params[:workspace_id]).first
    unless workspace.nil?
      member = Member.where(user: current_user, workspace: workspace)
      unless member.nil?
        @current_workspace = workspace
        return
      end
    end

    fail "Invalid workspace ID: #{params[:workspace_id]}."
  end

  def find_workspaces
    @workspaces = Member.where(user: current_user).collect(&:workspace)
  end

  def pager_params
    @limit = params[:limit].to_i
    @limit = 10 if @limit <= 0 || @limit > 100
    @after = params[:after]
    @before = params[:before]
  end

  def find_sequence
    name = params[:name] || params[:sequence_name]
    @sequence = Sequence.find(params[:workspace_id], name)
  end
end
