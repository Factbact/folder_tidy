-- Downloads Organizer
-- ダウンロードフォルダを自動整理 + 元に戻す機能

property historyFile : ((path to home folder as text) & ".downloads_organizer_history.txt")

on run
    set downloadsPath to POSIX path of (path to downloads folder)
    
    repeat
        try
            set dialogResult to display dialog "Downloads Organizer

対象: " & downloadsPath & "

何をしますか？" buttons {"終了", "元に戻す", "整理実行"} default button 3 with title "Downloads Organizer"
            set userChoice to button returned of dialogResult
        on error
            exit repeat
        end try
        
        if userChoice is "終了" then
            exit repeat
        else if userChoice is "整理実行" then
            set moveCount to doOrganize(downloadsPath)
            if moveCount > 0 then
                display dialog "完了！

" & moveCount & "件のファイルを整理しました。
「元に戻す」で復元できます。" buttons {"OK"} default button 1 with title "Downloads Organizer"
            else
                display dialog "整理するファイルがありませんでした。" buttons {"OK"} default button 1 with title "Downloads Organizer"
            end if
        else if userChoice is "元に戻す" then
            doUndo()
        end if
    end repeat
end run

on doOrganize(downloadsPath)
    set moveCount to 0
    set historyData to ""
    
    -- File extension mappings
    set docExts to {".pdf", ".doc", ".docx", ".txt", ".rtf", ".md"}
    set imgExts to {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".svg"}
    set vidExts to {".mp4", ".mov", ".mkv", ".avi", ".webm"}
    set audExts to {".mp3", ".wav", ".m4a", ".aac", ".flac"}
    set arcExts to {".zip", ".rar", ".7z", ".tar", ".gz", ".tgz"}
    set insExts to {".dmg", ".pkg", ".exe"}
    
    tell application "Finder"
        set downloadsFolder to POSIX file downloadsPath as alias
        set fileList to every file of downloadsFolder
        
        repeat with aFile in fileList
            set fileName to name of aFile as text
            set lowerName to do shell script "echo " & quoted form of fileName & " | tr '[:upper:]' '[:lower:]'"
            set targetCategory to ""
            
            -- Determine category
            repeat with ext in docExts
                if lowerName ends with ext then set targetCategory to "Documents"
            end repeat
            repeat with ext in imgExts
                if lowerName ends with ext then set targetCategory to "Images"
            end repeat
            repeat with ext in vidExts
                if lowerName ends with ext then set targetCategory to "Videos"
            end repeat
            repeat with ext in audExts
                if lowerName ends with ext then set targetCategory to "Audio"
            end repeat
            repeat with ext in arcExts
                if lowerName ends with ext then set targetCategory to "Archives"
            end repeat
            repeat with ext in insExts
                if lowerName ends with ext then set targetCategory to "Installers"
            end repeat
            
            if targetCategory is not "" then
                set sourcePath to POSIX path of (aFile as alias)
                set destFolder to downloadsPath & targetCategory & "/"
                set destPath to destFolder & fileName
                
                try
                    do shell script "mkdir -p " & quoted form of destFolder
                    do shell script "mv " & quoted form of sourcePath & " " & quoted form of destPath
                    set historyData to historyData & sourcePath & "|" & destPath & "
"
                    set moveCount to moveCount + 1
                end try
            end if
        end repeat
    end tell
    
    -- Save history
    if moveCount > 0 then
        try
            set historyRef to open for access file historyFile with write permission
            set eof of historyRef to 0
            write historyData to historyRef
            close access historyRef
        on error
            try
                close access file historyFile
            end try
        end try
    end if
    
    return moveCount
end doOrganize

on doUndo()
    try
        set historyData to read file historyFile
    on error
        display dialog "元に戻す履歴がありません。" buttons {"OK"} default button 1 with title "Downloads Organizer"
        return
    end try
    
    if historyData is "" then
        display dialog "元に戻す履歴がありません。" buttons {"OK"} default button 1 with title "Downloads Organizer"
        return
    end if
    
    set restoredCount to 0
    set historyLines to paragraphs of historyData
    
    repeat with aLine in historyLines
        if aLine is not "" then
            set AppleScript's text item delimiters to "|"
            set parts to text items of aLine
            set AppleScript's text item delimiters to ""
            
            if (count of parts) >= 2 then
                set originalPath to item 1 of parts
                set movedPath to item 2 of parts
                try
                    do shell script "mv " & quoted form of movedPath & " " & quoted form of originalPath
                    set restoredCount to restoredCount + 1
                end try
            end if
        end if
    end repeat
    
    -- Clear history
    try
        do shell script "rm -f " & quoted form of POSIX path of historyFile
    end try
    
    display dialog restoredCount & "件のファイルを元に戻しました。" buttons {"OK"} default button 1 with title "Downloads Organizer"
end doUndo
