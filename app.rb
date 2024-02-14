require 'sinatra'
require 'firebase'
require 'json'
require 'net/http'
require 'uri'
require 'date'
require 'cgi'
require 'csv'
require 'httparty'

FIREBASE_URL = "https://marketing-data-d141d-default-rtdb.firebaseio.com/"
FIREBASE_API_KEY = "AIzaSyCCTeiCYTB_npcWKKxl-Oj0StQLTmaFOaE"
firebase_url = "https://marketing-data-d141d-default-rtdb.firebaseio.com/"
firebase_secret = "FlE36axXatiyqZ9LaLHqb6HG9Z8vplUS1LYpIFSu"

# FIREBASE_URL = "https://onwords-master-db-default-rtdb.firebaseio.com/"
# FIREBASE_API_KEY = "AIzaSyBb1Age-jnJPIQJDnGFEtbAUPfJm7GdBiI"
# firebase_url = "https://onwords-master-db-default-rtdb.firebaseio.com/"
# firebase_secret = "dZ3YsARVGgTLK1IxplfLfNyh5B890uh7DdIhwLzR"

firebase = Firebase::Client.new(firebase_url, firebase_secret)

ENV['TZ'] = 'UTC'
set :bind, '0.0.0.0'
set :port, 8080
set :public_folder, 'public'
enable :sessions

def firebase
  @firebase ||= Firebase::Client.new("https://marketing-data-d141d-default-rtdb.firebaseio.com/", "FlE36axXatiyqZ9LaLHqb6HG9Z8vplUS1LYpIFSu")
end

# def firebase
#   @firebase ||= Firebase::Client.new("https://onwords-master-db-default-rtdb.firebaseio.com/", "AIzaSyBb1Age-jnJPIQJDnGFEtbAUPfJm7GdBiI")
# end

error do
  redirect to('/not_found')
end

get '/not_found' do
  status 404
  erb :error
end

before do
  uid = session[:user_uid]
  @user_details = get_staff_data(uid) if uid
  response.set_cookie('user_uid', value: uid, path: '/', max_age: '2592000')
end

before do
  suggestions = firebase.get('suggestion').body || {}
  @unread_count = suggestions.count { |_, suggestion| !suggestion['isread'] }
end

def count_not_done(data)
  return 0 if data.nil? || data.empty?

  count = 0
  data.each do |_id, schedules|
    schedules.each do |_dateKey, details|
      count += 1 unless details['is_done']
    end
  end
  count
end

before do
  if request.path_info != '/login' && session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    user_name = @user_details['name']

    @not_done_calls = 0
    @not_done_visits = 0
    @not_done_installations = 0
    @not_done_services = 0

    %w[calls visits services installations].each do |category|
      data = firebase.get(category).body || {}
      count = 0
      data.each do |_id, schedules|
        schedules.each do |_dateKey, details|
          if details['tagged_staff']&.include?(user_name) && !details['is_done']
            count += 1
          end
        end
      end
      instance_variable_set("@not_done_#{category}", count)
    end

    suggestions = firebase.get('suggestion').body || {}
    unread_count = suggestions.count { |_, suggestion| !suggestion['isread'] }
    @unread_count = unread_count
  end
end

def sign_in_with_email_and_password(email, password)
  uri = URI.parse("https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=#{FIREBASE_API_KEY}")
  request = Net::HTTP::Post.new(uri)
  request.content_type = "application/json"
  request.body = JSON.dump({
                             "email" => email,
                             "password" => password,
                             "returnSecureToken" => true
                           })

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(request)
  end

  JSON.parse(response.body)
end

def create_user_with_email_and_password(email, password)
  uri = URI.parse("https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=#{FIREBASE_API_KEY}")
  request = Net::HTTP::Post.new(uri)
  request.content_type = "application/json"
  request.body = JSON.dump({
                             "email" => email,
                             "password" => password,
                             "returnSecureToken" => true
                           })

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(request)
  end

  JSON.parse(response.body)
end

def get_staff_details(uid)
  response = firebase.get("staff/#{uid}")
  response.success? ? response.body : nil
end

def get_staff_data(uid)
  response = firebase.get("staff_details/#{uid}")
  response.success? ? response.body : nil
end

def fetch_inventory_data
  response = firebase.get("inventory_management")
  response.success? ? response.body : {}
end

post '/login' do
  email = params[:email]
  password = params[:password]

  begin
    user_data = sign_in_with_email_and_password(email, password)
    user_uid = user_data['localId']
    session[:user_uid] = user_uid
    redirect '/'
  rescue => e
    @error_message = 'Invalid email or password'
    erb :login
  end
end

get '/login' do
  erb :login
end

get '/logout' do
  session.clear
  response.delete_cookie('user_token')
  redirect to('/login')
end

get '/' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)

    suggestions = firebase.get('suggestion').body || {}
    unread_count = suggestions.count { |_, suggestion| !suggestion['isread'] }
    erb :home, locals: { unread_count: unread_count }
  else
    redirect to('/login')
  end
end

post '/order' do
  if params[:drink].nil? || params[:drink].empty?
    return 'Please select a drink.'
  end

  drink = params[:drink].downcase
  uid = session[:user_uid]
  @user_details = get_staff_details(uid)
  name = @user_details['name']

  time = Time.now
  formatted_date = time.strftime('%Y-%m-%d')
  hour_min = time.hour * 100 + time.min

  timeslot = if hour_min.between?(330, 545)
               'FN'
             elsif hour_min.between?(900, 1030)
               'AN'
             else
               nil
             end

  return 'Orders are not accepted at this time' unless timeslot

  if params[:lunch] == 'lunch' && timeslot == 'FN'
    lunch_path = "refreshments/#{formatted_date}/Lunch/lunch_list"
    current_lunch_data = firebase.get(lunch_path).body || {}

    if current_lunch_data.values.include?(name)
      return 'You have already ordered lunch for today.'
    end

    next_lunch_index = current_lunch_data.keys.count { |k| k.start_with?('name') } + 1
    firebase.update(lunch_path, { "name#{next_lunch_index}" => name })
    firebase.update("refreshments/#{formatted_date}/Lunch", { "lunch_count" => next_lunch_index })

  elsif params[:lunch] == 'lunch' && timeslot != 'FN'
    return 'Lunch can only be ordered between 09:00 to 10:45'
  end

  if %w[coffee tea milk].include?(drink)
    drink_path = "refreshments/#{formatted_date}/#{timeslot}/#{drink}"
    timeslot_path = "refreshments/#{formatted_date}/#{timeslot}"
    current_drink_data = firebase.get(drink_path).body || {}

    if current_drink_data.values.include?(name)
      return "You have already ordered #{drink} for this session."
    end

    next_index = current_drink_data.keys.count { |k| k.start_with?('name') } + 1
    current_count_data = firebase.get("#{timeslot_path}/#{drink}_count").body
    drink_count = current_count_data.to_i
    update_drink_data = { "name#{next_index}" => name }
    update_count_data = { "#{drink}_count" => drink_count + 1 }
    firebase.update(drink_path, update_drink_data)
    firebase.update(timeslot_path, update_count_data)
  else
    return "Invalid drink type."
  end

  "Order for #{drink} added successfully!"
end

get '/get_orders' do
  time = Time.now
  formatted_date = time.strftime('%Y-%m-%d')
  hour_min = time.hour * 100 + time.min

  timeslot = if hour_min.between?(900, 1045)
               'FN'
             elsif hour_min.between?(1400, 1530)
               'AN'
             else
               nil
             end

  return 'Invalid timeslot' unless timeslot

  path = "refreshments/#{formatted_date}/#{timeslot}"
  orders = firebase.get(path).body
  orders.to_json
end

post '/suggestion' do
  return 'Give a suggestion.' if params[:message].nil? || params[:message].empty?

  uid = session[:user_uid]
  @user_details = get_staff_details(uid)

  time_now = Time.now
  formatted_time = time_now.strftime('%Y-%m-%d_%H:%M:%S')
  suggestion_data = {
    date: time_now.strftime('%Y-%m-%d'),
    isread: false,
    message: params[:message],
    time: time_now.strftime('%H:%M'),
    uid: uid
  }
  suggestion_path = "suggestion/#{formatted_time}"
  firebase.set(suggestion_path, suggestion_data)
  redirect to('/')
end

get '/notifications' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)

    suggestions = firebase.get('suggestion').body || {}
    erb :notifications, locals: { suggestions: suggestions }

  else
    redirect to('/login')
  end
end

post '/mark_as_read' do
  request_data = JSON.parse(request.body.read)
  key = request_data['key']
  suggestion_path = "suggestion/#{key}"
  firebase.update(suggestion_path, { isread: true })
  "Marked as read successfully!"
end

get '/states' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)

    response = firebase.get('customer')

    if response.success?
      customers = response.body.values

      @state_counts = {}

      customers.each do |customer|
        state = customer['customer_state']
        if @state_counts[state]
          @state_counts[state] += 1
        else
          @state_counts[state] = 1
        end
      end

      @states = @state_counts.keys
    else
      @states = []
      @state_counts = {}
    end

    erb :states

  else
    redirect to('/login')
  end
end

get '/customers_by_state' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    selected_state = params['state']
    response = firebase.get('customer')
    if response.success?
      customers = response.body.values
      @customers = customers.select { |customer| customer['customer_state'] == selected_state }
    else
      @customers = []
    end
    erb :customers_by_state
  else
    redirect to('/login')
  end
end

get '/customer_profile' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    phone_number = params['phone_number']
    response = firebase.get('customer')
    staff_response = firebase.get('staff_details')
    if response.success?
      customers = response.body.values
      all_staff = staff_response.body
      @staff_names = all_staff.select { |_uid, details| details['department'] == 'PR' }.map { |_uid, details| details['name'] }
      @customer_profile = customers.find { |customer| customer['phone_number'] == params[:phone_number] }
      @states = customers.map { |customer| customer['customer_state'] }.uniq
    else
      @customer_profile = {}
      @states = []
      @staff_names = {}
    end
    erb :customer_profile
  else
    redirect to('/login')
  end
end

get '/customer_profile/:phone_number' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    phone_number = params['phone_number']
    response = firebase.get('customer')
    staff_response = firebase.get('staff_details')
    if response.success?
      customers = response.body.values
      all_staff = staff_response.body
      @staff_names = all_staff.select { |_uid, details| details['department'] == 'PR' }.map { |_uid, details| details['name'] }
      @customer_profile = customers.find { |customer| customer['phone_number'] == phone_number }
      @states = customers.map { |customer| customer['customer_state'] }.uniq
    else
      @customer_profile = {}
      @states = []
      @staff_names = {}
    end
    erb :customer_profile
  else
    redirect to('/login')
  end
end

post '/update_customer_state' do
  phone_number = params['phone_number']
  new_state = params['state']
  response = firebase.get('customer')
  if response.success?
    customers = response.body
    customer_key = customers.find { |key, value| value['phone_number'] == phone_number }&.first
    if customer_key
      update_response = firebase.update("customer/#{customer_key}", { 'customer_state' => new_state })
    else
      "Customer not found"
    end
  else
    "Failed to retrieve customers"
  end
  redirect to("/customer_profile/#{phone_number}")
end

post '/update_LeadIncharge' do
  phone_number = params['phone_number']
  new_Incharge = params['lead_incharge']
  response = firebase.get('customer')
  if response.success?
    customers = response.body
    customer_key = customers.find { |key, value| value['phone_number'] == phone_number }&.first
    if customer_key
      update_response = firebase.set("customer/#{customer_key}/LeadIncharge", new_Incharge)
    else
       "Customer not found"
    end
  else
    "Failed to retrieve customers"
  end
  redirect to("/customer_profile/#{phone_number}")
end

post '/add_notes' do
  phone_number = params['phone_number']
  name = params['entered_by']
  note = params['note']
  date = Time.now
  datetime_key = date.strftime("%Y-%m-%d_%H:%M:%S")
  notes_path = "customer/#{phone_number}/notes/#{datetime_key}"
  note_data = { date: datetime_key.split('_').first, time: datetime_key.split('_').last, note: note, entered_by: name }
  update_response = firebase.set(notes_path, note_data)
  redirect to("/customer_profile/#{phone_number}")
end

get '/create_staff' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    staff_response = firebase.get('staff_details')
    @staff_list = staff_response.success? ? staff_response.body : {}
    erb :create_staff
  else
    redirect to('/login')
  end
end

post '/create_staff' do
  name = params[:name]
  email = params[:email]
  password = params[:password]
  department = params[:department]
  user_data = create_user_with_email_and_password(email, password)
  if user_data['localId']
    firebase.set("staff_details/#{user_data['localId']}", { 'name' => name, 'email' => email, 'department' => department })
    firebase.set("staff/#{user_data['localId']}", {
      'name' => name,
      'email' => email,
      'department' => department,
      'punch_in' => '09:00',
      'punch_out' => '18:00'
    })
    redirect to('/attendance')
  else
    @error_message = 'Failed to create staff'
    erb :create_staff
  end
end

get '/delete_staff' do
  staff_response = firebase.get('staff_details')
  if staff_response.success?
    @staff_list = staff_response.body
  else
    @staff_list = {}
  end
  erb :create_staff
end

post '/delete_staff' do
  uid = params[:uid]
  firebase.delete("staff_details/#{uid}")
  firebase.delete("staff/#{uid}")
  redirect to('/create_staff')
end

get '/attendance' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    selected_date = params['date'] ? Date.parse(params['date']) : Date.today
    year = selected_date.year.to_s
    month = selected_date.strftime("%m")
    day = selected_date.strftime("%d")

    attendance_response = firebase.get("attendance/#{year}/#{month}/#{day}")
    staff_response = firebase.get('staff_details')

    @attendance_records = []
    all_staff = staff_response.success? && staff_response.body.is_a?(Hash) ? staff_response.body : {}

    if attendance_response.success? && attendance_response.body.is_a?(Hash)
      todays_attendance = attendance_response.body

      todays_attendance.each do |uid, times|
        staff_name = all_staff[uid]['name'] if all_staff[uid]
        @attendance_records.push({ 'date' => "#{year}-#{month}-#{day}", 'name' => staff_name, 'check_in' => times['check_in'], 'check_out' => times['check_out'] })
      end
    end

    absentees = all_staff.keys - todays_attendance.keys
    @absentees_details = absentees.map do |uid|
      { 'name' => all_staff[uid]['name'], 'department' => all_staff[uid]['department'] }
    end
    erb :attendance
  else
    redirect to('/login')
  end
end

get '/attendance/monthly_summary' do
  if session[:user_uid]
    begin
      month_param = params['month']
      if month_param
        date_parts = month_param.split('-').map(&:to_i)
        selected_month = Date.new(date_parts[0], date_parts[1], 1)
      else
        selected_month = Date.today
      end
      selected_year = selected_month.year
      start_date = Date.new(selected_year, selected_month.month, 1)
      end_date = Date.new(selected_year, selected_month.month, -1)

      @present_count = Hash.new(0)
      @absent_count = Hash.new(0)

      staff_response = firebase.get('staff_details')
      @all_staff = staff_response.success? && staff_response.body.is_a?(Hash) ? staff_response.body : {}

      (start_date..end_date).each do |date|
        year = date.year.to_s
        month = date.strftime("%m")
        day = date.strftime("%d")

        attendance_response = firebase.get("attendance/#{year}/#{month}/#{day}")

        if attendance_response.success? && attendance_response.body.is_a?(Hash)
          todays_attendance = attendance_response.body
          @all_staff.each do |uid, _|
            if todays_attendance.key?(uid)
              @present_count[uid] += 1
            else
              @absent_count[uid] += 1
            end
          end
        end
      end
      erb :monthly_attendance
    rescue ArgumentError
      redirect to('/login')
    end
  else
    redirect to('/login')
  end
end

get '/inventory' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    @inventory_items = fetch_inventory_data
    erb :inventory
  else
    redirect to('/login')
  end
end

post '/inventory/add' do
  id = params[:id]
  name = params[:name]
  max_price = params[:max_price]
  min_price = params[:min_price]
  obc = params[:obc]
  stock = params[:stock]
  data_to_add = { 'id' => id, 'name' => name, 'max_price' => max_price, 'min_price' => min_price, 'obc' => obc, 'stock' => stock }
  response = firebase.update("inventory_management/#{id}", data_to_add)

  [201, response.body.to_json]
  redirect to('/inventory')
end

post '/inventory/update/:id' do
  item_id = params[:id]
  updated_item_data = JSON.parse(request.body.read)
  existing_item_data = firebase.get("inventory_management/#{item_id}").body
  if existing_item_data
    merged_item_data = existing_item_data.merge(updated_item_data)
    firebase.update("inventory_management/#{item_id}", merged_item_data)
    status 200
    body 'Item updated successfully'
  else
    status 404
    body 'Item not found'
  end
end

post '/inventory/delete/:id' do
  firebase.delete("inventory_management/#{params[:id]}")
  @inventory_items = fetch_inventory_data
  erb :inventory
end

get '/invoice' do
  invoice_response = firebase.get('QuotationAndInvoice/INVOICE')
  @invoice_data = invoice_response.body
  erb :files
end

get '/quotation' do
  quotation_response = firebase.get('QuotationAndInvoice/QUOTATION')
  @quotation_data = quotation_response.body
  erb :files
end

get '/proforma-invoice' do
  proforma_response = firebase.get('QuotationAndInvoice/PROFORMA_INVOICE')
  @proforma_data = proforma_response.body
  erb :files
end

get '/create_lead' do
  if session[:user_uid]
    uid = session[:user_uid]
    staff_response = firebase.get('staff_details')
    all_staff = staff_response.body
    @user_details = get_staff_details(uid)
    @staff_names = all_staff.select { |_uid, details| details['department'] == 'PR' }.map { |_uid, details| [details['name'], _uid] }

    if @user_details
      erb :create_lead
    else
      "Error: Unable to fetch user details."
    end
  else
    redirect '/login'
  end
end

post '/create_lead' do
  content_type :text
  uid = session[:user_uid]
  user_details = get_staff_details(uid)
  LeadIncharge = params[:lead_incharge].empty? ? "Not Assigned" : params[:lead_incharge]

  unless params[:file] && params[:file][:tempfile] && params[:file][:filename]
    return "No file selected!"
  end

  file = params[:file][:tempfile]
  inquired_for = params[:EnquiredFor]

  current_date = Date.today.to_s
  current_time = Time.now.strftime("%H:%M:%S")

  default_values = {
    "created_by" => user_details ? user_details['name'] : "Unknown",
    "created_date" => current_date,
    "created_time" => current_time,
    "customer_state" => "New leads",
    "LeadIncharge" => LeadIncharge,
    "inquired_for" => inquired_for
  }

  added_numbers = []
  error_messages = []
  lead_incharge_buckets = {}

  begin
    file_contents = file.read.encode("UTF-8", "binary", invalid: :replace, undef: :replace, replace: '')
    file_contents.gsub!("\r", "\n")

    CSV.parse(file_contents, headers: true, liberal_parsing: true) do |row|
      lead_details = row.to_hash.merge(default_values)
      lead_details['phone_number'] = lead_details['phone_number'].to_s.gsub('p:', '').gsub('+91', '') if lead_details['phone_number']
      phone_number = lead_details['phone_number']

      if phone_number && !phone_number.empty?
        begin
          existing_lead = firebase.get("customer/#{phone_number}").body
          if existing_lead
            updated_lead_details = existing_lead.merge(lead_details)
            firebase.update("customer/#{phone_number}", updated_lead_details)
          else
            firebase.set("customer/#{phone_number}", lead_details)
          end

          unless lead_incharge_buckets.has_key?(LeadIncharge)
            last_bucket_info = firebase.get("Bucket/#{LeadIncharge}/Counter").body
            if last_bucket_info && !last_bucket_info.empty?
              last_bucket_number = last_bucket_info.keys.max_by { |k| k.match(/\d+/)[0].to_i }
              last_counter_value = last_bucket_info[last_bucket_number]
              lead_incharge_buckets[LeadIncharge] = { bucket_number: last_bucket_number.gsub(/[^\d]/, '').to_i, counter: last_counter_value.to_i }
            else
              lead_incharge_buckets[LeadIncharge] = { bucket_number: 1, counter: 0 }
            end
          end

          lead_incharge_bucket = lead_incharge_buckets[LeadIncharge]

          if lead_incharge_bucket[:counter] >= 50
            lead_incharge_bucket[:bucket_number] += 1
            lead_incharge_bucket[:counter] = 0
          end

          lead_incharge_bucket[:counter] += 1
          formatted_bucket_number = format('%02d', lead_incharge_bucket[:bucket_number])
          phone_index = lead_incharge_bucket[:counter]
          formatted_phone_index = format('%02d', phone_index)

          bucket_counter_key = "Bucket/#{LeadIncharge}/Counter/Bucket#{formatted_bucket_number}"
          firebase.set(bucket_counter_key, phone_index)

          bucket_key = "Bucket/#{LeadIncharge}/Bucket#{formatted_bucket_number}/#{formatted_phone_index}"
          firebase.set(bucket_key, phone_number)
          added_numbers.push(phone_number)
        rescue => e
          error_messages.push("Error with phone number #{phone_number}: #{e.message}")
        end
      else
        error_messages.push("Invalid or empty phone number at row: #{row.inspect}")
      end
    end

    message = ""
    if added_numbers.any?
      message += "Successfully created/updated leads for phone numbers: #{added_numbers.join(', ')}. "
    end
    if error_messages.any?
      message += "Errors: #{error_messages.join(' ')}"
    end

    message.empty? ? "No new leads were created/updated." : message
  rescue CSV::MalformedCSVError => e
    "CSV Malformed Error: #{e.message}"
  rescue => e
    "Unknown error: #{e.message}"
  end
end

post '/create_custom_lead' do
  content_type :text
  uid = session[:user_uid]
  user_details = get_staff_details(uid)
  name = params[:name]
  phone_number = params[:phone]
  email_id = params[:email]
  inquired_for = params[:enquiredFor]
  data_fetched_by = params[:source]
  location = params[:location]
  current_date = Date.today.to_s
  current_time = Time.now.strftime("%H:%M:%S")
  lead_data = { "name" => name, "email_id" => email_id, "inquired_for" => inquired_for, "phone_number" => phone_number, "data_fetched_by" => data_fetched_by, "created_by" => user_details ? user_details['name'] : "Unknown", "created_date" => current_date, "created_time" => current_time, "customer_state" => "New leads", "LeadIncharge" => "Not Assigned", "city" => location }
  firebase.update("customer/#{phone_number}", lead_data)
  "Lead created successfully for phone number: #{phone_number}"
end

get '/bulk_assign' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    response = firebase.get('customer')
    staff_response = firebase.get('staff_details')
    if response.success?
      customers = response.body.values
      all_staff = staff_response.body
      @customers = response.body.values.select { |customer| customer['customer_state'] == params['state'] }
      @staff_names = all_staff.select { |_uid, details| details['department'] == 'PR' }.map { |_uid, details| [details['name'], _uid] }
      @customer_profile = customers.find { |customer| customer['phone_number'] == params[:phone_number] }
      @states = customers.map { |customer| customer['customer_state'] }.uniq
    else
      @customer_profile = {}
      @states = []
      @staff_names = {}
      @customers = []
    end
    erb :bulk_assign
  else
    redirect to('/login')
  end
end

post '/bulk_assign' do
  content_type :json

  if session[:user_uid]
    request_body = JSON.parse(request.body.read)
    phone_numbers = request_body['phone_numbers']
    new_incharge = request_body['new_incharge']

    if new_incharge && phone_numbers && phone_numbers.is_a?(Array)
      phone_numbers.each do |phone_number|
        customer_key = firebase.get('customer').body.find { |key, value| value['phone_number'] == phone_number }&.first
        firebase.set("customer/#{customer_key}/LeadIncharge", new_incharge) if customer_key
      end
      { status: 'success', message: 'Incharge assigned successfully.' }.to_json
    else
      { status: 'error', message: 'Invalid parameters.' }.to_json
    end
  else
    redirect to('/login')
  end
end

get '/get_customers_by_state' do
  if session[:user_uid]
    state = params['state']
    response = firebase.get('customer')
    if response.success?
      customers = response.body.values
      filtered_customers = customers.select { |customer| customer['customer_state'] == state }
      content_type :json
      filtered_customers.to_json
    else
      status 404
    end
  else
    redirect to('/login')
  end
end

get '/get_customers_by_incharge' do
  if session[:user_uid]
    incharge = params['incharge']
    response = firebase.get('customer')
    if response.success?
      customers = response.body.values
      filtered_customers = customers.select { |customer| customer['LeadIncharge'] == incharge }
      content_type :json
      filtered_customers.to_json
    else
      status 404
    end
  else
    redirect to('/login')
  end
end

post '/request_feedback' do
  content_type :json
  begin
    request_payload = JSON.parse(request.body.read)
    customer_phone_number = request_payload['customerPhoneNumber']
    cust_name = request_payload['cust_name']
    telecaller_name = request_payload['telecaller_name']

    url = "https://live-server-116191.wati.io/api/v2/sendTemplateMessage?whatsappNumber=#{customer_phone_number}"
    data = {
      "template_name" => "telecall_feedback",
      "broadcast_name" => "Feedback Request",
      "parameters" => [
        {"name" => "cust_name", "value" => cust_name},
        {"name" => "telecaller_name", "value" => telecaller_name}
      ]
    }
    headers = {
      'Content-Type' => 'application/json',
      'Authorization' => 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiI4YzE4ZjU4Yy0zNTgwLTQ0MTAtYjU4NS1lNjNhN2YzNzYwYTgiLCJ1bmlxdWVfbmFtZSI6ImNlb0BvbndvcmRzLmluIiwibmFtZWlkIjoiY2VvQG9ud29yZHMuaW4iLCJlbWFpbCI6ImNlb0BvbndvcmRzLmluIiwiYXV0aF90aW1lIjoiMTAvMjAvMjAyMyAxNjo0MzozMyIsImRiX25hbWUiOiIxMTYxOTEiLCJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL3dzLzIwMDgvMDYvaWRlbnRpdHkvY2xhaW1zL3JvbGUiOiJBRE1JTklTVFJBVE9SIiwiZXhwIjoyNTM0MDIzMDA4MDAsImlzcyI6IkNsYXJlX0FJIiwiYXVkIjoiQ2xhcmVfQUkifQ.pVIcK8y9jgncGeD9VGdP6EW-YIbDazCFI86GMzfndsc'
    }

    response = HTTParty.post(url, body: data.to_json, headers: headers)
    if response.success?
      {message: "Message sent successfully!"}.to_json
    else
      status 500
      {error: "Failed to send message"}.to_json
    end
  rescue => e
    status 500
    puts "Error: #{e.message}"
    {error: "Error sending message."}.to_json
  end
end

get '/get_staff_details' do
  staff_members = []
  response = firebase.get("staff_details")
  if response.success?
    staff_data = response.body
    staff_data.each do |uid, details|
      staff_members << { uid: uid, name: details['name'] }
    end
  else
    status 500
    return "Failed to retrieve staff details"
  end
  content_type :json
  staff_members.to_json
end

get '/my_clients' do
  if session[:user_uid]
    @user_details = get_staff_details(session[:user_uid])
    erb :my_clients
  else
    redirect to('/login')
  end
end

get '/fetch_my_clients' do
  if session[:user_uid]
    name = get_staff_details(session[:user_uid])['name']

    response = firebase.get('customer')
    if response.success?
      customers = response.body.values
      filtered_customers = customers.select { |customer| customer['LeadIncharge'] == name }
      content_type :json
      filtered_customers.to_json
    else
      status 404
    end
  else
    status 403
  end
end

post '/add_schedule' do
  created_by = params[:entered_by]
  phone_number = params[:phone_number]
  scheduled_date = params[:scheduled_date]
  scheduled_time = params[:scheduled_time]
  schedule_note = params[:schedule_note]
  schedule_type = params[:schedule_type]
  tagged_staff = params[:staff_members]
  date = Time.now
  datetime_key = date.strftime("%Y-%m-%d_%H:%M:%S")

  valid_schedule_types = %w[visits calls services installations]
  unless valid_schedule_types.include?(schedule_type)
    status 400
    return "Invalid schedule type"
  end

  schedule_path = "#{schedule_type}/#{phone_number}/#{datetime_key}"
  schedule_data = {
    created_by: created_by,
    scheduled_date: scheduled_date,
    scheduled_time: scheduled_time,
    schedule_note: schedule_note,
    tagged_staff: tagged_staff
  }
  response = firebase.update(schedule_path, schedule_data)
end

get '/schedules' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)

    @not_done_calls = count_not_done(firebase.get('calls').body)
    @not_done_visits = count_not_done(firebase.get('visits').body)
    @not_done_services = count_not_done(firebase.get('services').body)
    @not_done_installations = count_not_done(firebase.get('installations').body)

    erb :schedules
  else
    redirect to('/login')
  end
end

get '/scheduled_calls' do
  content_type :json
  firebase.get('calls').body.to_json
end

get '/scheduled_visits' do
  content_type :json
  firebase.get('visits').body.to_json
end

get '/scheduled_services' do
  content_type :json
  firebase.get('services').body.to_json
end

get '/scheduled_installations' do
  content_type :json
  firebase.get('installations').body.to_json
end

post '/mark_done/:category/:phone_number/:date_time_key' do
  category = params[:category]
  phone_number = params[:phone_number]
  date_time_key = params[:date_time_key]
  updated_notes = params[:updated_notes]
  schedule_path = "#{category}/#{phone_number}/#{date_time_key}"
  schedule = firebase.get(schedule_path).body
  schedule['is_done'] = true
  schedule['updated_notes'] = updated_notes
  schedule['completed_time'] = Time.now.strftime("%Y-%m-%d_%H:%M:%S")
  firebase.set(schedule_path, schedule)
  completed_path = "completed/#{category}/#{phone_number}/#{date_time_key}"
  firebase.set(completed_path, schedule)
  firebase.delete(schedule_path)
  redirect to('/schedules')
end

get '/view_completed_schedules' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)
    @done = firebase.get('completed').body || {}
    erb :view_completed_schedules
  else
    redirect to('/login')
  end
end

get '/calendar' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)

    @not_done_calls = count_not_done(firebase.get('calls').body)
    @not_done_visits = count_not_done(firebase.get('visits').body)
    @not_done_services = count_not_done(firebase.get('services').body)
    @not_done_installations = count_not_done(firebase.get('installations').body)

    erb :calendar
  else
    redirect to('/login')
  end
end

get '/batch' do
  if session[:user_uid]
    uid = session[:user_uid] || request.cookies['uid']
    @user_details = get_staff_details(uid)

    response = firebase.get('customer')

    if response.success?
      customers = response.body.values

      @month_counts = {}
      @customers = []
      @staff_names = {}

      customers.each do |customer|
        next if customer['created_date'].nil?

        month_year = customer['created_date'][0..6]
        if @month_counts[month_year]
          @month_counts[month_year] += 1
        else
          @month_counts[month_year] = 1
        end
      end

      @months = @month_counts.keys.sort
    else
      @months = []
      @month_counts = {}
    end
    erb :batches
  else
    redirect to('/login')
  end
end

get '/get_customers_by_batch' do
  if session[:user_uid]
    batch = params['batch']
    response = firebase.get('customer')
    staff_response = firebase.get('staff_details')

    if response.success?
      customers = response.body.values
      all_staff = staff_response.body
      @staff_names = all_staff.select { |_uid, details| details['department'] == 'PR' }.map { |_uid, details| [details['name'], _uid] }
      @customers = customers.select do |customer|
        next if customer['created_date'].nil?
        customer['created_date'][0..6] == batch
      end

      @months = []
      @month_counts = {}
      customers.each do |customer|
        next if customer['created_date'].nil?
        month_year = customer['created_date'][0..6]
        if @month_counts[month_year]
          @month_counts[month_year] += 1
        else
          @month_counts[month_year] = 1
        end
      end
      @months = @month_counts.keys.sort

      erb :batches
    else
      status 404
      erb :error
    end
  else
    redirect to('/login')
  end
end

get '/filter_customers' do
  if session[:user_uid]
    batch = params['batch']
    incharge_uid = params['incharge']
    response = firebase.get('customer')

    if response.success?
      customers = response.body.values
      filtered_customers = customers.select do |customer|
        next if customer['created_date'].nil?
        customer['created_date'][0..6] == batch && customer['LeadIncharge'] == incharge_uid
      end

      filtered_customers.to_json
    else
      status 404
      { error: 'Data not found' }.to_json
    end
  else
    redirect to('/login')
  end
end

def fetch_buckets
  uri = URI("#{FIREBASE_URL}/Bucket.json")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Get.new(uri.request_uri)
  response = http.request(request)
  JSON.parse(response.body)
end

def fetch_customer_state(phone_number)
  uri = URI("#{FIREBASE_URL}/customer/#{phone_number}.json")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Get.new(uri.request_uri)
  response = http.request(request)
  customer_data = JSON.parse(response.body)
  customer_data["customer_state"] rescue nil
end

def fetch_buckets_with_customer_states
  buckets_data = fetch_buckets
  buckets_data.each do |name, details|
    details["Bucket01"].each do |key, phone_number|
      customer_state = fetch_customer_state(phone_number)
      details["Bucket01"][key] = { "phone_number" => phone_number, "customer_state" => customer_state }
    end
  end
  buckets_data
end

def get_customer_states_for_name_and_bucket(name, bucket_name)
  all_states_count = Hash.new(0)
  buckets_data = fetch_buckets

  if buckets_data.key?(name) && buckets_data[name].key?(bucket_name)
    buckets_data[name][bucket_name].each do |_, phone_number|
      customer_state = fetch_customer_state(phone_number)
      all_states_count[customer_state] += 1 unless customer_state.nil?
    end
  end

  all_states_count.map { |state, count| { state: state || "Unknown", count: count } }
end

get '/view_buckets' do
  if session[:user_uid]
    @data = fetch_buckets
    erb :view_buckets
  else
    redirect to('/login')
  end
end

get '/customer_states/:name/:bucket' do
  content_type :json
  name = params[:name]
  bucket = params[:bucket]
  customer_states_data = get_customer_states_for_name_and_bucket(name, bucket)
  customer_states_data.to_json
end