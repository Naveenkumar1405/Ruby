$(document).ready(function() {
    let scheduleData = {};

    $('#callsButton').click(function() { fetchAndDisplayData('calls'); });
    $('#visitsButton').click(function() { fetchAndDisplayData('visits'); });
    $('#servicesButton').click(function() { fetchAndDisplayData('services'); });
    $('#installationsButton').click(function() { fetchAndDisplayData('installations'); });

    function fetchAndDisplayData(type) {
        $.get('/scheduled_' + type, function(data) {
            scheduleData = {};
            Object.entries(data).forEach(([phoneNumber, scheduleDetails]) => {
                Object.entries(scheduleDetails).forEach(([dateTimeKey, details]) => {
                    let date = details.scheduled_date;
                    if (!scheduleData[date]) scheduleData[date] = [];
                    scheduleData[date].push({ type, phoneNumber, details, dateKey: dateTimeKey });
                });
            });
            initCalendar();
        });
    }

    const calendar = document.querySelector(".calendar"),
        date = document.querySelector(".date"),
        daysContainer = document.querySelector(".days"),
        prev = document.querySelector(".prev"),
        next = document.querySelector(".next"),
        todayBtn = document.querySelector(".today-btn"),
        gotoBtn = document.querySelector(".goto-btn"),
        dateInput = document.querySelector(".date-input"),
        eventsContainer = document.querySelector(".events"),
        eventDay = document.querySelector(".event-day"),
        eventDate = document.querySelector(".event-date");

    let today = new Date();
    let month = today.getMonth();
    let year = today.getFullYear();

    const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

    function initCalendar() {
        const firstDay = new Date(year, month, 1);
        const lastDay = new Date(year, month + 1, 0);
        const prevLastDay = new Date(year, month, 0);
        const prevDays = prevLastDay.getDate();
        const lastDate = lastDay.getDate();
        const day = firstDay.getDay();
        const nextDays = 7 - lastDay.getDay() - 1;

        date.innerHTML = `${months[month]} ${year}`;
        let days = "";

        // Days from the previous month
        for (let x = day; x > 0; x--) {
            days += `<div class="day prev-date">${prevDays - x + 1}</div>`;
        }

        // Current month's days with schedule data
        for (let i = 1; i <= lastDate; i++) {
            let formattedDate = `${year}-${String(month + 1).padStart(2, '0')}-${String(i).padStart(2, '0')}`;
            if (scheduleData[formattedDate]) {
                days += `<div class="day event" data-date="${formattedDate}">${i}</div>`;
            } else {
                days += `<div class="day" data-date="${formattedDate}">${i}</div>`;
            }
        }

        // Days from the next month
        for (let j = 1; j <= nextDays; j++) {
            days += `<div class="day next-date">${j}</div>`;
        }

        daysContainer.innerHTML = days;
        addListener();
    }

    function addListener() {
        document.querySelectorAll('.day').forEach(day => {
            day.addEventListener('click', function() {
                document.querySelectorAll('.day').forEach(d => d.classList.remove('active'));
                this.classList.add('active');
                let selectedDate = this.getAttribute('data-date');
                if (selectedDate) {
                    updateDateDisplay(selectedDate);
                    updateEvents(selectedDate);
                }
            });
        });
    }

    function updateDateDisplay(selectedDate) {
        const dateObj = new Date(selectedDate);
        const dayOfWeek = dateObj.toLocaleString('en-US', { weekday: 'short' }); // e.g., "Wed"
        const formattedDate = dateObj.toLocaleDateString('en-US', { day: 'numeric', month: 'long', year: 'numeric' }); // e.g., "12th December 2022"

        $('.event-day').text(dayOfWeek);
        $('.event-date').text(formattedDate);
    }

    function updateEvents(selectedDate) {
        let eventsHtml = '';

        if (scheduleData[selectedDate]) {
            eventsHtml = scheduleData[selectedDate].map(event => {
                return `<div class="event-details">
                <div>Created Date: <span>${event.dateKey}</span></div>
                <div>Phone: <span><a href="/customer_profile/${event.phoneNumber}">${event.phoneNumber}</a></span></div>
                <div>Type: <span>${event.type}</span></div>
                <div>Note: <span>${event.details.schedule_note}</span></div>
                <div>Time: <span>${event.details.scheduled_time}</span></div>
                <div>Scheduled by: <span>${event.details.created_by}</span></div>
                <div>Tagged Staff: <span>${event.details.tagged_staff}</span></div>
                <form action="/mark_done/${event.type}/${event.phoneNumber}/${event.dateKey}" method="post">
                    <input type="text" name="updated_notes" placeholder="update notes">
                    <button type="submit">Mark as Done</button>
                </form>
            </div>`;
            }).join('');
        } else {
            eventsHtml = `<div class="no-event">No events</div>`;
        }
        $('#scheduleData').html(eventsHtml);
    }

    prev.addEventListener("click", () => {
        month--;
        if (month < 0) {
            month = 11;
            year--;
        }
        initCalendar();
    });

    next.addEventListener("click", () => {
        month++;
        if (month > 11) {
            month = 0;
            year++;
        }
        initCalendar();
    });

    todayBtn.addEventListener("click", () => {
        today = new Date();
        month = today.getMonth();
        year = today.getFullYear();
        initCalendar();
    });

    dateInput.addEventListener("input", (e) => {
        dateInput.value = dateInput.value.replace(/[^0-9/]/g, "");
        if (dateInput.value.length === 2) {
            dateInput.value += "/";
        }
        if (dateInput.value.length > 7) {
            dateInput.value = dateInput.value.slice(0, 7);
        }
        if (e.inputType === "deleteContentBackward") {
            if (dateInput.value.length === 3) {
                dateInput.value = dateInput.value.slice(0, 2);
            }
        }
    });

    gotoBtn.addEventListener("click", gotoDate);

    function gotoDate() {
        console.log("here");
        const dateArr = dateInput.value.split("/");
        if (dateArr.length === 2) {
            if (dateArr[0] > 0 && dateArr[0] < 13 && dateArr[1].length === 4) {
                month = dateArr[0] - 1;
                year = dateArr[1];
                initCalendar();
                return;
            }
        }
        alert("Invalid Date");
    }

    function getActiveDay(date) {
        const day = new Date(year, month, date);
        const dayName = day.toString().split(" ")[0];
    }
    initCalendar();
});