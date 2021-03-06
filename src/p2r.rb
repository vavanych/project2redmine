# Copyright (c) 2019 NPO Karat
# Author: Aleksei Siventsev
#=====================================================================
# Console Script for MS Project to Redmine synchronization
#=====================================================================
VER = '0.3 22/05/19'
HDR = "Console Script for MS Project to Redmine synchronization v#{VER} (c) A. Siventsev 2019"

require 'yaml'
require 'win32ole'
require 'net/http'
require 'json'
require 'date'
require 'certified'
require './p2r_lib.rb'

require 'openssl'
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

#ENV['HTTP_DEBUG']

puts '', HDR, ('=' * HDR.scan(/./mu).size), ''


#---------------------------------------------------------------------
# process command line arguments
#---------------------------------------------------------------------
# answer help request and exit
chk !(ARGV & %w(h H -h -H /h /H ? -? /? help -help --help)).empty?, HELP
# check execution request
DRY_RUN = (ARGV & %w(e E -e -E /e /E exec -exec --exec execute -execute --execute)).empty?
puts "DRY RUN (add -e key for actual execution)\n\n" if DRY_RUN

#---------------------------------------------------------------------
# connect to .msp
#---------------------------------------------------------------------
msg = 'Please open your MS Project file and leave it active with no dialogs open'
begin
  pserver = WIN32OLE.connect 'MSProject.Application'
rescue
  chk true, msg
end
$msp = pserver.ActiveProject
chk !$msp,msg
$msp_name = $msp.Name.clone.encode 'UTF-8'

#---------------------------------------------------------------------
# find and process settings task
#---------------------------------------------------------------------
settings_task = nil
(1..$msp.Tasks.Count).each do |i|
  raw = $msp.Tasks(i)
  if raw && raw.Name == 'Redmine Synchronization'
    settings_task = raw
    break
  end
end
chk !settings_task, 'ERROR: task with name \'Redmine Sysncronization\' was not found in the project.'

begin
  $settings = YAML.load settings_task.Notes.to_s.gsub("\r", "\n")
rescue
  chk true, 'ERROR: could not extract settiings from Notes in \'Redmine Sysncronization\' task (YAML format expected)'
end

rmp_id = $settings.delete 'redmine_project_id'
missed_pars = %w(redmine_host redmine_api_key redmine_project_uuid resource_default_redmine_role_id) - $settings.keys

chk !missed_pars.empty?, "ERROR: following settings not found in 'Redmine Sysncronization' task: #{missed_pars.sort.join ', '}"

$settings['redmine_root'] = '' if !$settings['redmine_root']
$settings['protocol'] = ($settings['redmine_port'] == 80)? 'http': 'https'

#---------------------------------------------------------------------
# check Redmine project availability
#---------------------------------------------------------------------
# 401 ERROR: not authorized bad key
# 404 not found
#   if rpr_id then ERROR: suppose project has been published already
#   else project is to be published
# 403 forbidden
# 200 ок
#   if rpr_id then
#     if prp_id == project id then OK to proceed
#     else ERROR: different ids in project and redmine
#   else ERROR: suppose project is to be published but found it is already published
#

$uuid = $settings['redmine_project_uuid']
project_path="/projects/#{$uuid}.json"
re = rm_request(project_path)

case re.code
  when '401'
    chk true, 'ERROR: not authorized by Redmine (maybe bad api key?)'
  when '404'
    if rmp_id # else proceed
      chk true, "ERROR: suppose project '#{$uuid}' has been published already (because redmine_project_id is provided) but have not found it"
    end
  when '403'
    chk true, "ERROR: access to project '#{$uuid}' in Redmine is forbidden, ask Redmine admin"
  when '200'
    begin
      rmp = JSON.parse(re.body)
    rescue
      chk true, "ERROR: wrong reply format to '/projects/#{$uuid}.json' (JSON expected)"
    end
    rmp = rmp['project']
    chk !rmp, "ERROR: wrong reply format to '/projects/#{$uuid}.json' ('project' key not found)"
    if rmp_id
      unless rmp_id == rmp['id'] # else proceed
        chk true, "ERROR: Redmine project id does not comply with redmine_project_id provided in settings"
      end
    else
      chk true, "ERROR: suppose have to create new project '#{$uuid}' (because redmine_project_id is not provided) but found the project with that uuid has been published already"
    end
  else
    chk true, "ERROR: #{re.code} #{re.message}"
end

#---------------------------------------------------------------------
# check default tracker and role
#---------------------------------------------------------------------

if (($dflt_tracker_id = $settings['task_default_redmine_tracker_id']))
  chk !$dflt_tracker_id.is_a?(Integer), "ERROR: parameter task_default_redmine_tracker_id must be integer"
  trackers = rm_get '/trackers.json', 'trackers', 'ERROR: could not get Redmine tracker list'
  found = false
  trackers.each do |t|
    if (t['id'] = $dflt_tracker_id)
      found=true
      break
    end
  end
  chk !found, "ERROR: tracker not found for parameter task_default_redmine_tracker_id = #{$dflt_tracker_id}"
end

$dflt_role_id = $settings['resource_default_redmine_role_id']
chk !$dflt_tracker_id.is_a?(Integer), "ERROR: parameter task_default_redmine_tracker_id must be integer"
rm_get "/roles/#{$dflt_role_id}.json", 'role', "ERROR: could not get default team role resource_default_redmine_role_id=#{$dflt_role_id}"

#---------------------------------------------------------------------
# util for loading redmine users
#---------------------------------------------------------------------
$users = {}
def load_users
  offset = 0
  loop do
    re = rm_request "/users.json?offset=#{offset}"
    chk (re.code != '200'), 'ERROR: could not get Redmine users'
    re = JSON.parse(re.body) rescue nil
    chk re.nil?, 'ERROR: could not parse reply of users list request'
    break if re['users'].empty? or re['limit'].nil?
    re['users'].each do |m|
      $users[m['id']] = m
    end
    offset += re['limit']
  end
end

#---------------------------------------------------------------------
# util for loading project team
#---------------------------------------------------------------------
$team = {}
def load_team
  offset = 0
  loop do
    re = rm_request "/projects/#{$uuid}/memberships.json?offset=#{offset}"
    chk (re.code != '200'), 'ERROR: could not get team list of Redmine project'
    re = JSON.parse(re.body) rescue nil
    chk re.nil?, 'ERROR: could not parse reply of team list request'
    break if re['memberships'].empty? or re['limit'].nil?
    re['memberships'].each do |m|
      $team[m['user']['id']] = m
    end
    offset += re['limit']
  end
end

#---------------------------------------------------------------------
# some utils for msp custom fields editing
#---------------------------------------------------------------------
def set_mst_url(mst, rmt_id)
  url="#{$settings['protocol']}://#{$settings['redmine_host']}:#{$settings['redmine_port']}#{$settings['redmine_root']}/issues/#{rmt_id}"
  mst.HyperlinkAddress = url
  return url
end

#---------------------------------------------------------------------
# some utils for msp custom fields editing
#---------------------------------------------------------------------
def set_msr_url(msr, rmu_id)
  msr.Hyperlink = rmu_id
  url="#{$settings['protocol']}://#{$settings['redmine_host']}:#{$settings['redmine_port']}#{$settings['redmine_root']}/people/#{rmu_id}"
  msr.HyperlinkAddress = url
end

#---------------------------------------------------------------------
# task (issue) processing util
#---------------------------------------------------------------------

$rmts={} # issues processed
$rmus=[] # memberships processed
$skipped=[] #not synchronized task list
$msp_updated=[] #msp tasks updated
$rmt_updated=[] #redmine tasks updated

def process_issue rmp_id, mst, force_new_task = false, is_group = false

  mst_name = mst.Name.clone.encode 'UTF-8'
  rmt_id = mst.Hyperlink

  if ! (rmt_id =~ /^\s*\d+\s*$/) # task not marked for sync
    if $skipped.index(mst.ID).nil?
      puts "MSP #{mst.ID} '#{mst_name}': Skipping !!!"
      $skipped.push(mst.ID)
    end
    return nil
  else
    rmt_id = rmt_id.to_i
  end

  if (rmt = $rmts[rmt_id])
    return rmt # already processed
  end

  rmt = nil
  if rmt_id != 0 
    re = rm_request "/issues/#{rmt_id}.json?include=watchers"
    rmt = JSON.parse(re.body)['issue'] rescue nil if re.is_a? Net::HTTPOK
    if !rmt
      puts "MSP #{mst.ID} '#{mst_name}': Redmine issue# #{rmt_id} not found!!!"
      rmt_id = 0
    end
  end
  
  # process task parent:
  mst_papa = mst.OutlineParent
  rmt_papa = nil
  unless mst_papa.UniqueID == 0 # suppose project summary task has UniqueID = 0
    rmt_papa_id = mst_papa.Hyperlink
    if rmt_papa_id =~ /^\s*\d+\s*$/
      rmt_papa_id = rmt_papa_id.to_i
      rmt_papa = $rmts[rmt_papa_id]
      unless rmt_papa
        rmt_papa = process_issue rmp_id, mst_papa, force_new_task, true
      end
    else
      rmt_papa_id = 0
      #mst_papa.Hyperlink = '0'
      rmt_papa = process_issue rmp_id, mst_papa, false, true
    end

  end

  # check task resource appointment
  #   we expect not more than one synchronizable appointment
  rmu_id_ok = nil
  msr_ok = nil
  watcher_ids = []
  
  (1..mst.Resources.Count).each do |j|
    next unless (msr = mst.Resources(j))
    rmu_id = msr.Hyperlink
    next unless rmu_id =~ /^\s*\d+\s*$/ # resource not marked for sync
    
    if rmu_id == '0'
      rmu_name = msr.Initials
      rm_user = $users.find {|key, value| value['login'] == rmu_name}
      if !rm_user
        user = {}
        user["login"] = rmu_name
        user["generate_password"] = true
        user["firstname"] = rmu_name
        user["lastname"] = msr.Name
        user["admin"] = false
        user["mail"] = rmu_name + '@email.com'
        
        if DRY_RUN
          rmu_id = 1000+j
          puts "User " + user.to_s + " will be created"
          user["id"] = rmu_id
          $users[rmu_id] = user
        else
          rmu_id = create_redmine_user(user)
          puts "User " + user.to_s + " created"
        end
      else
        rmu_id = rm_user[0]
      end
      if (!DRY_RUN)
        set_msr_url msr, rmu_id
      end
    end

    rmu_id = rmu_id.to_i
    watcher_ids.push rmu_id if (j > 1)
    
    if !$rmus.include? rmu_id
      member = $team[rmu_id]
      unless member
        # Redmine user is not team member - create new membership
        # check user availability
        #re = rm_request "/users/#{rmu_id}.json"
        #chk (re.code != '200'), "ERROR: Redmine user #{rmu_id} not found for resource in MSP task #{mst.ID} '#{mst_name}'"
        #re = JSON.parse(re.body) rescue nil
        #chk re.nil?, "ERROR: could not parse reply: Redmine user #{rmu_id} not found for resource in MSP task #{mst.ID} '#{mst_name}'"
        # create membership
        if DRY_RUN
          puts "User " + rmu_name + " is not a member of project. Membership will be created"
          member = {'id': $team.size+1, 'user': {'id': rmu_id, 'name': rmu_name}}
        else
          data = {user_id: rmu_id, role_ids: [$dflt_role_id]}
          member = rm_create "/projects/#{$uuid}/memberships.json", 'membership', data,
                          "ERROR: could not create Redmine project membership for user #{rmu_id}"
          puts "New membership created for user: #{rmu_id}"
        end
        $team[rmu_id] = member
      end
    end

    if 1 == j
      rmu_id_ok = rmu_id
      msr_ok = msr      
    end
  end

  if rmu_id_ok
    rmu_name = $users[rmu_id_ok]['firstname']
    msr_name = msr_ok.Name.clone.encode 'UTF-8'
    unless rmu_name == msr_name
      puts "WARNING: RM user ID=#{rmu_id_ok} name '#{rmu_name}' does not correspond to MSP resource name '#{msr_name}' (task ##{rmt_id} for #{mst.ID} '#{mst_name}')"
    end
  end

  if rmt_id == 0 || force_new_task
    # create new task
    unless DRY_RUN
      rmt = {
          project_id: rmp_id, subject: mst_name, description: "-----\nAutocreated by P2R from MSP task #{mst.ID} in MSP project #{$msp_name}\n-----\n",
          start_date: mst.Start.strftime('%Y-%m-%d'), due_date: mst.Finish.strftime('%Y-%m-%d'),
          assigned_to_id: rmu_id_ok, tracker_id: $dflt_tracker_id,
          parent_issue_id: (rmt_papa ? rmt_papa['id'] : '')
      }
      rmt['watcher_user_ids'] = watcher_ids if !watcher_ids.empty?
      rmt['estimated_hours'] = (mst.Work/60.0).round(2) unless is_group
      rmt = rm_create '/issues.json', 'issue', rmt,
                      "ERROR: could not create Redmine task from #{mst.ID} '#{mst_name}' for some reasons"
      # write new task number to MSP
      mst.Hyperlink = rmt['id']
      set_mst_url mst, rmt['id']
      puts "Created task Redmine ##{rmt['id']} from MSP #{mst.ID} '#{mst_name}'"
      $rmt_updated.push rmt['id']
      $rmts[rmt['id']] = rmt
      return rmt
    else
      if !$rmts[mst.ID]
        $rmts[mst.ID] = 1 
      # keep task to be created
        puts "Will create task #{mst.ID} '#{mst_name}'"
      end
      return nil
    end
  else
    # update existing task
    #   check for changes
    #     to RM: subject - Name, parent_id - OutlineParent.Hyperlink, assigned_to_id - rmu_id_ok
    #     to MSP: start_date - Start, due_date - Finish, estimated_hours - Work, sum of reports - ActualWork

    # collect changes to RM
    changes={}
    changes['assigned_to_id'] = (rmu_id_ok || '') if rmu_id_ok != (rmt['assigned_to'] ? rmt['assigned_to']['id'] : nil)
    changes['subject'] = mst_name if rmt['subject'] != mst_name
    rmt_papa_id_old = (rmt['parent'] ? rmt['parent']['id'] : '')
    rmt_papa_id_new = (rmt_papa ? rmt_papa['id'] : '')
    changes['parent_issue_id'] = rmt_papa_id_new if rmt_papa_id_new != rmt_papa_id_old
    if !watcher_ids.empty?
      m = rmt['watchers'].map{|item| item['id']}
      changes['watcher_user_ids'] = watcher_ids if (m != watcher_ids)
    end
#    if rmt['estimated_hours'] && (rmt['estimated_hours'].round(2) != rmt['estimated_hours'])
#      rmt['estimated_hours'] = rmt['estimated_hours'].round(2)
#      changes['estimated_hours'] = rmt['estimated_hours']
#    end
  
    # collect changes to MSP
    unless is_group
      changes2={}
      d = mst.Start.strftime('%Y-%m-%d')
      changes2['start_date'] = rmt['start_date'] if rmt['start_date'] != d
      d = mst.Finish.strftime('%Y-%m-%d')
      changes2['due_date'] = rmt['due_date'] if rmt['due_date'] != d
      # calculate estimate and spent hours
      spent = (rmt['spent_hours'] || 0.0) * 60.0
      changes2['spent_hours'] = spent if spent != mst.ActualWork
      est = (rmt['estimated_hours'] || 0.0) * 60.0
      if rmt['done_ratio'] > 0 && spent > 0
        # we will consider priority of done ratio over estimated hours
        est = (spent * 100.0 / rmt['done_ratio']).round(2)
      elsif rmt['done_ratio'] == 0 && spent > 0
        # done ratio is wrong
        if est >= spent
          # some discrepancy - we will fix done ratio in RM
          changes['done_ratio'] = spent * 100.0 / est
        else
          # some error in estimate? we will ignore estimate and warn
          est = nil
          puts "Warning: estimated hours less than spent hours, estimate will be ignored"
        end
      end
      if est && est.round(0) != mst.Work
        changes2['estimated_hours'] = est 
      end
    end

    # apply changes to RM
    if changes.empty?
      puts "No changes for Task Redmine ##{rmt_id} from MSP #{mst.ID} '#{mst_name}'"
    else
      # apply changes
      changelist = changes.keys.join(', ')
      changes['notes'] = "Autoupdated by P2P at #{Time.now.strftime '%Y-%m-%d %H:%M'} (#{changelist})"
      if DRY_RUN
        puts "Will update task Redmine ##{rmt_id} from MSP #{mst.ID} '#{mst_name}' (#{changelist})"
      else
        rm_update "/issues/#{rmt['id']}.json",  {issue: changes},
                  "ERROR: could not update Redmine task ##{rmt['id']} from #{mst.ID} '#{mst_name}' for some reasons"
        rmt = rm_get "/issues/#{rmt_id}.json", 'issue', "ERROR: could not find Redmine task ##{rmt_id} for #{mst.ID} '#{mst_name}'"
        puts "Updated task Redmine ##{rmt_id} from MSP #{mst.ID} '#{mst_name}' (#{changelist})"
        $rmt_updated.push rmt_id
      end
    end

    # apply changes to MSP
    unless is_group
      if changes2.empty?
        puts "No changes for MSP task #{mst.ID} '#{mst_name}'"
      else
        # apply changes
        changelist2 = changes2.keys.join(', ')
        if DRY_RUN
          puts "Will update MSP task #{mst.ID} '#{mst_name}'  from Redmine ##{rmt_id} (#{changelist2})"
        else
          changes2.each do |k,v|
            case k
              when 'start_date'; mst.Start = Time.new *(v.split /\D+/ )
              when 'due_date';        mst.Finish = Time.new *(v.split /\D+/ )
              when 'spent_hours';     mst.ActualWork = v
              when 'estimated_hours'; mst.Work = v
            end
          end
          puts "Updated MSP task #{mst.ID} '#{mst_name}' from Redmine ##{rmt_id} (#{changelist2})"
          $msp_updated.push mst.ID
        end
      end
    end
    set_mst_url mst, rmt['id']

    $rmts[rmt['id']] = rmt
    return rmt

  end

end

#---------------------------------------------------------------------
# iterate over task list
#---------------------------------------------------------------------
def process_issues rmp_id, force_new_task = false

  (1..$msp.Tasks.Count).each do |i|

    # check msp task
    next unless (mst = $msp.Tasks(i))

    is_group = (mst.OutlineChildren.Count > 0)
    process_issue rmp_id, mst, force_new_task, is_group

  end
end
#---------------------------------------------------------------------
# create new user 
# @returns user_id
#---------------------------------------------------------------------
def create_redmine_user (user)
  new_user = rm_create '/users.json', 'user', user,
  "ERROR: could not create Redmine user from #{user['login']} '#{user['name']}' for some reasons"
  $users[new_user['id']] = new_user
  return new_user['id']
end
#=====================================================================
# main work cycle
#=====================================================================
settings_task.Start = Time.now unless DRY_RUN

if rmp_id
  #=====================================================================
  # existing Redmine project update
  #---------------------------------------------------------------------
  puts 'Existing Redmine project update'

else
  #=====================================================================
  # new Redmine project creation
  #---------------------------------------------------------------------
  if DRY_RUN
    # project creation requested - exit on dry run
    chk true, "Will create new Redmine project #{$uuid} from MSP project #{$msp_name}"
  end

  #---------------------------------------------------------------------
  # new Redmine project create
  #---------------------------------------------------------------------
  rmp = {name: $msp_name, identifier: $uuid, is_public: false}
  rmp = rm_create '/projects.json', 'project', rmp,
      'ERROR: could not create Redmine project for some reasons'

  # add rm project id to msp settings
  $settings['redmine_project_id'] = rmp['id']
  settings_task.Notes = YAML.dump $settings
  puts "Created new Redmine project #{$uuid} ##{rmp['id']} from MSP project #{$msp_name}"

  #---------------------------------------------------------------------
  # add tasks to Redmine project
  #---------------------------------------------------------------------

end

load_users
load_team
process_issues (rmp_id || rmp['id']), rmp_id.nil?

settings_task.Finish = Time.now unless DRY_RUN

puts "----------------------------------------------------"
puts "MSP tasks skipped:      #{$skipped.size} -> #{$skipped}"
puts "Redmine issues updated: #{$rmt_updated.size} -> #{$rmt_updated}"
puts "MSP tasks updated:      #{$msp_updated.size} -> #{$msp_updated}"
