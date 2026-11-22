import QtQuick
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "calendarUtils.js" as CalendarUtils

PluginSettings {
    id: root
    pluginId: "dankCalendarAgenda"

    StyledText {
        width: parent.width
        text: "Dank Calendar Agenda"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Shows your next calendar event from dcal with a live countdown. Left click lists today's events (click one to open it), right click refreshes, middle click toggles the DankCalendar window."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: "Refresh Interval"
        description: "How often to fetch the next event (seconds)"
        defaultValue: 30
        minimum: 10
        maximum: 120
        unit: "sec"
        leftIcon: "schedule"
    }

    ToggleSetting {
        settingKey: "dynamicWidth"
        label: "Dynamic Width"
        description: "Shrink the horizontal pill to its contents instead of reserving the full width"
        defaultValue: false
    }

    SelectionSetting {
        settingKey: "pillDisplayMode"
        label: "Bar Display"
        description: "Choose which event details appear beside the calendar icon"
        options: [
            { label: "Title and countdown", value: "full" },
            { label: "Countdown only", value: "countdownOnly" },
            { label: "Title only", value: "titleOnly" }
        ]
        defaultValue: "full"
    }

    ToggleSetting {
        settingKey: "scrollTitle"
        label: "Scroll Long Titles"
        description: "Animate overflowing horizontal titles; otherwise truncate them on one line"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showTooltip"
        label: "Hover Tooltip"
        description: "Show the full event summary in a tooltip when hovering the widget"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "barContentWidth"
        label: "Bar Content Width"
        description: "Horizontal content budget including icon, title, countdown and Join (DMS adds outer padding)"
        defaultValue: CalendarUtils.contentWidth({pillMaxWidth: root.loadValue("pillMaxWidth", 160)})
        minimum: 120
        maximum: 600
        unit: "px"
        leftIcon: "width"
    }

    SliderSetting {
        settingKey: "nowWindowMinutes"
        label: "Now Duration"
        description: "How long to show 'Now' after an event starts (0 to disable)"
        defaultValue: 5
        minimum: 0
        maximum: 30
        unit: "min"
        leftIcon: "timelapse"
    }

    SliderSetting {
        settingKey: "agendaPastDays"
        label: "Agenda: Days Back"
        description: "How many past days the popout agenda keeps scrollable (it opens at today)"
        defaultValue: 7
        minimum: 0
        maximum: 90
        unit: "days"
        leftIcon: "history"
    }

    SliderSetting {
        settingKey: "agendaFutureDays"
        label: "Agenda: Days Ahead"
        description: "How many upcoming days the popout agenda covers"
        defaultValue: 30
        minimum: 7
        maximum: 90
        unit: "days"
        leftIcon: "view_agenda"
    }

    SelectionSetting {
        id: lookAheadUnit
        settingKey: "lookAheadUnit"
        label: "Look Ahead Unit"
        description: "Set the countdown window in days or hours"
        options: [
            { label: "Days", value: "days" },
            { label: "Hours", value: "hours" }
        ]
        defaultValue: "days"
    }

    SliderSetting {
        visible: lookAheadUnit.value !== "hours"
        settingKey: "lookAheadDays"
        label: "Look Ahead"
        description: "How many days ahead to check for events"
        defaultValue: 1
        minimum: 1
        maximum: 7
        unit: "days"
        leftIcon: "date_range"
    }

    SliderSetting {
        visible: lookAheadUnit.value === "hours"
        settingKey: "lookAheadHours"
        label: "Look Ahead"
        description: "Only count down to events starting within this many hours"
        defaultValue: 24
        minimum: 1
        maximum: 48
        unit: "h"
        leftIcon: "schedule"
    }

    ToggleSetting {
        settingKey: "hideWhenEmpty"
        label: "Hide When No Events"
        description: "Hide the bar pill when nothing starts within the look-ahead window (middle-click/IPC still work)"
        defaultValue: false
    }
}
