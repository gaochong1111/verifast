open Unix
open Verifast
open GMain
open Pervasives

type platform = Windows | Linux | MacOS

let platform = if Sys.os_type = "Win32" then Windows else if Fonts.is_macos then MacOS else Linux

let normalize_to_lf text =
  let n = String.length text in
  let buffer = Buffer.create n in
  let rec iter lfCount crCount crlfCount k =
    if k = n then begin
      let counts = [lfCount, platform = Linux || platform = MacOS, "\n"; crlfCount, platform = Windows, "\r\n"; crCount, false, "\r"] in
      let (_, _, eol)::_ = List.sort (fun x y -> - compare x y) counts in
      (eol, Buffer.contents buffer)
    end else
      let c = text.[k] in
      match c with
      | '\n' ->
        Buffer.add_char buffer c; iter (lfCount + 1) crCount crlfCount (k + 1)
      | '\r' ->
        if k + 1 < n && text.[k + 1] = '\n' then begin
          Buffer.add_char buffer '\n'; iter lfCount crCount (crlfCount + 1) (k + 2)
        end else begin
          Buffer.add_char buffer '\n'; iter lfCount (crCount + 1) crlfCount (k + 1)
        end
      | c ->
        Buffer.add_char buffer c; iter lfCount crCount crlfCount (k + 1)
  in
  iter 0 0 0 0

let convert_eol eol text =
  let n = String.length text in
  let buffer = Buffer.create n in
  let rec iter k =
    if k = n then
      Buffer.contents buffer
    else
      match text.[k] with
      | '\n' ->
        Buffer.add_string buffer eol; iter (k + 1)
      | '\r' ->
        if k + 1 < n && text.[k + 1] = '\n' then begin
          Buffer.add_string buffer eol; iter (k + 2)
        end else begin
          Buffer.add_string buffer eol; iter (k + 1)
        end
      | c ->
        Buffer.add_char buffer c; iter (k + 1)
  in
  iter 0

type undo_action =
  Insert of int * string
| Delete of int * string

let index_of_byref x xs =
  let rec iter k xs =
    match xs with
      [] -> raise Not_found
    | x0::xs -> if x0 == x then k else iter (k + 1) xs
  in
  iter 0 xs
  
let string_of_process_status s =
  match s with
    Unix.WEXITED n -> Printf.sprintf "WEXITED %d" n
  | Unix.WSIGNALED n -> Printf.sprintf "WSIGNALED %d" n
  | Unix.WSTOPPED n -> Printf.sprintf "WSTOPPED %d" n
  
let sys cmd =
  let chan = Unix.open_process_in cmd in
  let line = input_line chan in
  let exitStatus = Unix.close_process_in chan in
  if exitStatus <> Unix.WEXITED 0 then failwith (Printf.sprintf "Command '%s' failed with exit status %s" cmd (string_of_process_status exitStatus));
  line

let path_last_modification_time path =
  (Unix.stat path).st_mtime

let file_has_changed path mtime =
  try
    path_last_modification_time path <> mtime
  with Unix.Unix_error (_, _, _) -> true

let in_channel_last_modification_time chan =
  (Unix.fstat (Unix.descr_of_in_channel chan)).st_mtime

let out_channel_last_modification_time chan =
  (Unix.fstat (Unix.descr_of_out_channel chan)).st_mtime

let show_ide initialPath prover codeFont traceFont runtime =
  let ctxts_lifo = ref None in
  let msg = ref None in
  let url = ref None in
  let appTitle = "VeriFast " ^ Vfversion.version ^ " IDE" in
  let root = GWindow.window ~width:800 ~height:600 ~title:appTitle ~allow_shrink:true () in
  let fontScalePower = ref 0 in
  let getScaledFont fontName =
    if !fontScalePower = 0 then fontName else
    let fontDescription = new GPango.font_description (GPango.font_description fontName) in
    let size = float_of_int fontDescription#size in
    let size = size *. (1.3 ** float_of_int !fontScalePower) in
    let size = int_of_float size in
    fontDescription#modify ~size ();
    fontDescription#to_string
  in
  let codeFont = ref codeFont in
  let scaledCodeFont = ref !codeFont in
  let traceFont = ref traceFont in
  let scaledTraceFont = ref !traceFont in
  let actionGroup = GAction.action_group ~name:"Actions" () in
  let disableOverflowCheck = ref false in
  let simplifyTerms = ref true in
  let current_tab = ref None in
  let showLineNumbers enable =
    match !current_tab with
      None -> ()
    | Some tab ->
      tab#mainView#view#set_show_line_numbers enable;
      tab#subView#view#set_show_line_numbers enable
  in
  let showWhitespace enable =
    match !current_tab with
      None -> ()
    | Some tab ->
      let flags = if enable then [`SPACE; `TAB] else [] in
      tab#mainView#view#set_draw_spaces flags;
      tab#subView#view#set_draw_spaces flags
  in
  let showLineNumbersAction =
    let a = GAction.toggle_action ~name:"ShowLineNumbers" () in
    a#set_label "Show _line numbers"; ignore $. a#connect#toggled (fun () -> showLineNumbers a#get_active);
    a
  in
  let showWhitespaceAction =
    let a = GAction.toggle_action ~name:"ShowWhitespace" () in
    a#set_label "Show _whitespace"; ignore $. a#connect#toggled (fun () -> showWhitespace a#get_active);
    a
  in
  let _ =
    let a = GAction.add_action in
    GAction.add_actions actionGroup [
      a "File" ~label:"_File";
      a "New" ~stock:`NEW;
      a "Open" ~stock:`OPEN;
      a "Save" ~stock:`SAVE ~accel:"<control>S" ~tooltip:"Save";
      a "SaveAs" ~label:"Save _as";
      a "Close" ~stock:`CLOSE ~tooltip:"Close";
      a "Edit" ~label:"_Edit";
      a "Undo" ~stock:`UNDO ~accel:"<Ctrl>Z";
      a "Redo" ~stock:`REDO ~accel:"<Ctrl>Y";
      a "Preferences" ~label:"_Preferences...";
      a "View" ~label:"Vie_w";
      a "ClearTrace" ~label:"_Clear trace" ~accel:"<Ctrl>L";
      a "TextSize" ~label:"_Text size";
      a "TextLarger" ~label:"_Larger" ~accel:"<Alt>Up";
      a "TextSmaller" ~label:"_Smaller" ~accel:"<Alt>Down";
      a "TextSizeDefault" ~label:"_Default";
      (fun group -> group#add_action showLineNumbersAction);
      (fun group -> group#add_action showWhitespaceAction);
      a "Verify" ~label:"_Verify";
      GAction.add_toggle_action "CheckOverflow" ~label:"Check arithmetic overflow" ~active:true ~callback:(fun toggleAction -> disableOverflowCheck := not toggleAction#get_active);
      GAction.add_toggle_action "SimplifyTerms" ~label:"Simplify Terms" ~active:true ~callback:(fun toggleAction -> simplifyTerms := toggleAction#get_active);
      a "VerifyProgram" ~label:"Verify program" ~stock:`MEDIA_PLAY ~accel:"F5" ~tooltip:"Verify";
      a "RunToCursor" ~label:"_Run to cursor" ~stock:`JUMP_TO ~accel:"<Ctrl>F5" ~tooltip:"Run to cursor";
      a "Window" ~label:"_Window";
      a "Stub";
      a "Help" ~label:"_Help";
      a "About" ~stock:`ABOUT ~callback:(fun _ -> GToolbox.message_box "VeriFast IDE" (Verifast.banner ()))
    ]
  in
  let ui = GAction.ui_manager() in
  ui#insert_action_group actionGroup 0;
  root#add_accel_group ui#get_accel_group;
  ignore (ui#add_ui_from_string "
    <ui>
      <menubar name='MenuBar'>
        <menu action='File'>
          <menuitem action='New' />
          <menuitem action='Open' />
          <menuitem action='Save' />
          <menuitem action='SaveAs' />
          <menuitem action='Close' />
        </menu>
        <menu action='Edit'>
          <menuitem action='Undo' />
          <menuitem action='Redo' />
          <separator />
          <menuitem action='Preferences' />
        </menu>
        <menu action='View'>
          <menuitem action='ClearTrace' />
          <separator />
          <menu action='TextSize'>
            <menuitem action='TextLarger' />
            <menuitem action='TextSmaller' />
            <separator />
            <menuitem action='TextSizeDefault' />
          </menu>
          <separator />
          <menuitem action='ShowLineNumbers' />
          <menuitem action='ShowWhitespace' />
        </menu>
        <menu action='Verify'>
          <menuitem action='VerifyProgram' />
          <menuitem action='RunToCursor' />
          <separator />
          <menuitem action='CheckOverflow' />
          <menuitem action='SimplifyTerms' />
        </menu>
        <menu action='Window'>
           <menuitem action='Stub' />
        </menu>
        <menu action='Help'>
          <menuitem action='About'/>
        </menu>
      </menubar>
      <toolbar name='ToolBar'>
        <toolitem action='Save' />
        <toolitem action='Close' />
        <separator />
        <toolitem action='Undo' />
        <toolitem action='Redo' />
        <separator />
        <toolitem action='VerifyProgram' />
        <toolitem action='RunToCursor' />
      </toolbar>
    </ui>
  ");
  let undoAction = actionGroup#get_action "Undo" in
  let redoAction = actionGroup#get_action "Redo" in
  let windowMenuItem = new GMenu.menu_item (GtkMenu.MenuItem.cast (ui#get_widget "/MenuBar/Window")#as_widget) in
  let ignore_text_changes = ref false in
  let rootVbox = GPack.vbox ~packing:root#add () in
  rootVbox#pack (ui#get_widget "/MenuBar");
  let toolbar = new GButton.toolbar (GtkButton.Toolbar.cast (ui#get_widget "/ToolBar")#as_widget) in
  toolbar#set_icon_size `SMALL_TOOLBAR;
  toolbar#set_style `ICONS;
  let separatorToolItem = GButton.separator_tool_item () in
  toolbar#insert separatorToolItem;
  let messageToolItem = GButton.tool_item ~expand:true () in
  let messageHBox = GPack.hbox ~packing:(messageToolItem#add) () in
  messageToolItem#set_border_width 3;
  let messageEntry = GEdit.entry ~show:false ~editable:false ~has_frame:false ~packing:(messageHBox#add) () in
  messageEntry#coerce#misc#modify_font_by_name !scaledTraceFont;
  let helpButton = GButton.button ~show:false ~label:" ? " ~packing:(messageHBox#pack) () in
  let show_help url =
    if Sys.os_type = "Unix" then
     if sys "uname" = "Darwin" then
        ignore (Sys.command ("open " ^ "'" ^ bindir ^ "/../help/" ^ url ^ ".html" ^ "'"))
      else
        ignore (Sys.command ("xdg-open " ^ "'" ^ bindir ^ "/../help/" ^ url ^ ".html" ^ "'"))
    else
      (* The below command asynchronously launches a "cmd" process that launches the help topic.
         Launching the help topic synchronously seems to cause vfide to hang for between 6 and 30 seconds.
         My hypothesis is that "cmd /C start xyz.html" performs a DDE broadcast to all windows on the desktop,
         which apparently blocks until a timeout happens if some window is not responding. If the
         Help topic is launched synchronously inside the GUI event handler thread, the vfide window is not
         responsive until the Help topic is launched. Ergo the deadlock.
         This seems to be confirmed here <http://wiki.tcl.tk/996> and here <http://blogs.msdn.com/b/oldnewthing/archive/2007/02/26/1763683.aspx>.
      *)
      ignore (Unix.create_process "cmd" [| "/C"; "start"; "Dummy Title"; bindir ^ "\\..\\help\\" ^ url ^ ".html" |] Unix.stdin Unix.stdout Unix.stderr)
  in
  ignore (helpButton#connect#clicked (fun () -> (match(!url) with None -> () | Some(url) -> show_help url);));
  toolbar#insert messageToolItem;
  rootVbox#pack (toolbar#coerce);
  let rootTable = GPack.paned `VERTICAL ~border_width:3 ~packing:(rootVbox#pack ~expand:true) () in
  rootTable#set_position 400;
  let textPaned = GPack.paned `VERTICAL ~packing:(rootTable#pack1 ~resize:true ~shrink:true) () in
  textPaned#set_position 0;
  let srcPaned = GPack.paned `HORIZONTAL ~packing:(textPaned#pack2 ~resize:true ~shrink:true) () in
  srcPaned#set_position 650;
  let subPaned = GPack.paned `HORIZONTAL ~packing:(textPaned#pack1 ~resize:true ~shrink:true) () in
  subPaned#set_position 650;
  let textNotebook = GPack.notebook ~scrollable:true ~packing:(srcPaned#pack1 ~resize:true ~shrink:true) () in
  let subNotebook = GPack.notebook ~scrollable:true ~packing:(subPaned#pack1 ~resize:true ~shrink:true) () in
  let buffers = ref [] in
  let goto_tab tab =
    textNotebook#goto_page (index_of_byref tab !buffers)
  in
  let updateBufferMenu () =
    let menu = GMenu.menu () in
    let items = !buffers |> List.map (fun tab -> (match !(tab#path) with None -> "(Untitled)" | Some (path, mtime) -> path), tab) in
    let items = List.sort (fun (name1, _) (name2, _) -> compare name1 name2) items in
    items |> List.iter begin fun (name, tab) ->
      let item = GMenu.menu_item ~label:name ~packing:(menu#add) () in
      ignore (item#connect#activate (fun () -> goto_tab tab))
    end;
    windowMenuItem#set_submenu menu
  in
  let updateBufferTitle tab =
    let text = (match !(tab#path) with None -> "(New buffer)" | Some (path, mtime) -> Filename.basename path) ^ (if tab#buffer#modified then "*" else "") in
    tab#mainView#label#set_text text;
    tab#subView#label#set_text text
  in
  let bufferChangeListener = ref (fun _ -> ()) in
  let set_current_tab tab =
    current_tab := tab;
    match tab with
      None ->
      undoAction#set_sensitive false;
      redoAction#set_sensitive false;
      showLineNumbersAction#set_sensitive false;
      showWhitespaceAction#set_sensitive false
    | Some tab ->
      undoAction#set_sensitive (!(tab#undoList) <> []);
      redoAction#set_sensitive (!(tab#redoList) <> []);
      showLineNumbersAction#set_sensitive true;
      showLineNumbersAction#set_active (tab#mainView#view#show_line_numbers);
      showWhitespaceAction#set_sensitive true;
      showWhitespaceAction#set_active (tab#subView#view#draw_spaces <> [])
  in
  let tag_name_of_range_kind kind =
    match kind with
      KeywordRange -> "keyword"
    | GhostKeywordRange -> "ghostKeyword"
    | GhostRange -> "ghostRange"
    | GhostRangeDelimiter -> "ghostRangeDelimiter"
    | CommentRange -> "comment"
    | ErrorRange -> "error"
  in
  let srcpos_iter buffer (line, col) =
    (buffer#get_iter_at_byte ~line:(line - 1) 0)#set_line_index (col - 1) (* Hack, to work around an apparent Gtk or lablgtk bug *)
    (* buffer#get_iter (`LINEBYTE (line - 1, col - 1)) *)
  in
  let string_of_iter it = string_of_int it#line ^ ":" ^ string_of_int it#line_offset in
  let rec perform_syntax_highlighting tab start stop =
    let buffer = tab#buffer in
    let firstLine = buffer#start_iter#get_text ~stop:buffer#start_iter#forward_to_line_end in
    let {file_opt_annot_char=annotChar} = get_file_options firstLine in
    let commentTag = get $. GtkText.TagTable.lookup buffer#tag_table "comment" in
    let commentTag = new GText.tag commentTag in
    let ghostRangeTag = get $. GtkText.TagTable.lookup buffer#tag_table "ghostRange" in
    let ghostRangeTag = new GText.tag ghostRangeTag in
    let start = start#backward_line in
    let start = if start#line_index <> 0 then buffer#start_iter else start in (* Works around an apparent bug in backward_line *)
    let stop = stop#forward_line in
    let startLine = start#line in
    let startIsInComment = start#has_tag commentTag && not (start#begins_tag (Some commentTag)) in
    let startIsInGhostRange = start#has_tag ghostRangeTag && not (start#begins_tag (Some ghostRangeTag)) in
    let stopIsInComment = stop#has_tag commentTag && not (stop#begins_tag (Some commentTag)) in
    let stopIsInGhostRange = stop#has_tag ghostRangeTag && not (start#begins_tag (Some ghostRangeTag)) in
    buffer#remove_all_tags ~start:start ~stop:stop;
    let reportRange kind ((_, line1, col1), (_, line2, col2)) =
      buffer#apply_tag_by_name (tag_name_of_range_kind kind) ~start:(srcpos_iter buffer (startLine + line1, col1)) ~stop:(srcpos_iter buffer (startLine + line2, col2))
    in
    let text = start#get_text ~stop:stop in
    let highlight keywords =
      let (loc, ignore_eol, tokenStream, in_comment, in_ghost_range) =
        make_lexer_core keywords ghost_keywords ("<bufferBase>", "<buffer>") text reportRange startIsInComment startIsInGhostRange false (fun _ -> ()) annotChar in
      Stream.iter (fun _ -> ()) tokenStream;
      if not (stop#is_end) && (!in_comment, !in_ghost_range) <> (stopIsInComment, stopIsInGhostRange) then
        perform_syntax_highlighting tab stop buffer#end_iter
    in
    match !(tab#path) with
      None -> ()
    | Some (path, mtime) ->
      if Filename.check_suffix path ".c" then highlight (common_keywords @ c_keywords)
      else if Filename.check_suffix path ".h" then highlight (common_keywords @ c_keywords)
      else if Filename.check_suffix path ".java" then highlight (common_keywords @ java_keywords)
      else ()
  in
  let create_editor (textNotebook: GPack.notebook) buffer =
    let textLabel = GMisc.label ~text:"(untitled)" () in
    let textVbox = GPack.vbox ~spacing:2 ~packing:(fun widget -> ignore (textNotebook#append_page ~tab_label:textLabel#coerce widget)) () in
    let textFindBox = GPack.hbox ~show:false ~border_width:2 ~spacing:2 ~packing:(textVbox#pack ~expand:false) () in
    GMisc.label ~text:"Find:" ~packing:(textFindBox#pack ~expand:false) ();
    let textFindEntry = GEdit.entry ~packing:textFindBox#add () in
    let textScroll =
      GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN
        ~packing:textVbox#add () in
    let srcText = (*GText.view*) GSourceView2.source_view ~source_buffer:buffer ~packing:textScroll#add () in
    srcText#misc#modify_font_by_name !scaledCodeFont;
    ignore $. textFindEntry#event#connect#key_press (fun key ->
      if GdkEvent.Key.keyval key = GdkKeysyms._Escape then begin
        (new GObj.misc_ops srcText#as_widget)#grab_focus (); textFindBox#misc#hide (); true
      end else false
    );
    ignore $. textFindEntry#connect#activate (fun () ->
      let cursor = buffer#get_iter `INSERT in
      match cursor#forward_char#forward_search textFindEntry#text with
        None -> GToolbox.message_box "VeriFast IDE" "Text not found"
      | Some (iter1, iter2) ->
        buffer#select_range iter1 iter2;
        srcText#scroll_to_mark ~within_margin:0.2 `INSERT
    );
    ignore $. srcText#event#connect#key_press (fun key ->
      if GdkEvent.Key.keyval key = GdkKeysyms._f && List.mem `CONTROL (GdkEvent.Key.state key) then begin
        textFindBox#misc#show (); (new GObj.misc_ops textFindEntry#as_widget)#grab_focus (); true
      end else if GdkEvent.Key.keyval key = GdkKeysyms._d && List.mem `CONTROL (GdkEvent.Key.state key) then begin
        let cursor = buffer#get_iter `INSERT in
        cursor#tags |> List.iter (fun (tag: GText.tag) -> ignore (tag#event srcText#as_widget (key: GdkEvent.Key.t :> GdkEvent.any) cursor#as_iter));
        true
      end else if GdkEvent.Key.keyval key = GdkKeysyms._Return then
      begin
        let cursor = buffer#get_iter `INSERT in
        let lineStart = cursor#set_line_offset 0 in
        let rec iter home =
          if home#ends_line then home else if Glib.Unichar.isspace home#char then iter home#forward_char else home
        in
        let home = iter lineStart in
        let indent = lineStart#get_text ~stop:home in
        let eol = "\n" in
        buffer#insert (eol ^ indent);
        srcText#scroll_mark_onscreen `INSERT;
        true
      end
      else
        false
    );
    object method label = textLabel method page = textVbox method view = srcText end
  in
  let add_buffer() =
    let path = ref None in
    let buffer = GSourceView2.source_buffer () in
    let _ = buffer#create_tag ~name:"keyword" [`WEIGHT `BOLD; `FOREGROUND "Blue"] in
    let _ = buffer#create_tag ~name:"ghostRange" [`FOREGROUND "#CC6600"] in
    let _ = buffer#create_tag ~name:"ghostKeyword" [`WEIGHT `BOLD; `FOREGROUND "#DB9900"] in
    let _ = buffer#create_tag ~name:"comment" [`FOREGROUND "#008000"] in
    let _ = buffer#create_tag ~name:"ghostRangeDelimiter" [`FOREGROUND "Gray"] in
    let _ = buffer#create_tag ~name:"error" [`UNDERLINE `DOUBLE; `FOREGROUND "Red"] in
    let _ = buffer#create_tag ~name:"currentLine" [`BACKGROUND "Yellow"] in
    let _ = buffer#create_tag ~name:"currentCaller" [`BACKGROUND "Green"] in
    let currentStepMark = buffer#create_mark (buffer#start_iter) in
    let currentCallerMark = buffer#create_mark (buffer#start_iter) in
    let mainView = create_editor textNotebook buffer in
    let subView = create_editor subNotebook buffer in
    let undoList: undo_action list ref = ref [] in
    let redoList: undo_action list ref = ref [] in
    let eol = ref (if platform = Windows then "\r\n" else "\n") in
    let useSiteTags = ref [] in
    let tab = object
      method path = path
      method eol = eol
      method buffer = buffer
      method undoList = undoList
      method redoList = redoList
      method mainView = mainView
      method subView = subView
      method currentStepMark = currentStepMark
      method currentCallerMark = currentCallerMark
      method useSiteTags = useSiteTags
    end in
    ignore $. buffer#connect#modified_changed (fun () ->
      updateBufferTitle tab
    );
    ignore $. buffer#connect#insert_text (fun iter text ->
      if not !ignore_text_changes then
      begin
        let offset = iter#offset in
        undoList :=
          begin
            match !undoList with
              Insert (offset0, text0)::acs when offset = offset0 + String.length text0 ->
              Insert (offset0, text0 ^ text)::acs
            | acs -> Insert (offset, text)::acs
          end;
        redoList := [];
        undoAction#set_sensitive true;
        redoAction#set_sensitive false
      end
    );
    ignore $. buffer#connect#after#insert_text (fun iter text ->
      let start = iter#backward_chars (Glib.Utf8.length text) in
      perform_syntax_highlighting tab start iter
    );
    ignore $. buffer#connect#after#delete_range (fun ~start:start ~stop:stop ->
      perform_syntax_highlighting tab start stop
    );
    ignore $. buffer#connect#delete_range (fun ~start:start ~stop:stop ->
      if not !ignore_text_changes then
      begin
        let offset = start#offset in
        let text = buffer#get_text ~start:start ~stop:stop () in
        undoList := 
          begin
            match !undoList with
              Delete (offset0, text0)::acs when offset = offset0 ->
              Delete (offset0, text0 ^ text)::acs
            | acs -> Delete (offset, text)::acs
          end;
        redoList := [];
        undoAction#set_sensitive true;
        redoAction#set_sensitive false
      end
    );
    ignore $. buffer#connect#changed (fun () -> !bufferChangeListener tab);
    let focusIn _ = set_current_tab (Some tab); false in
    ignore $. mainView#view#event#connect#focus_in ~callback:focusIn;
    ignore $. subView#view#event#connect#focus_in ~callback:focusIn;
    buffers := !buffers @ [tab];
    tab
  in
  let setCodeFont fontName =
    codeFont := fontName;
    let scaledFont = getScaledFont fontName in
    scaledCodeFont := scaledFont;
    List.iter
      begin fun tab ->
        tab#mainView#view#misc#modify_font_by_name scaledFont;
        tab#subView#view#misc#modify_font_by_name scaledFont
      end
      !buffers
  in
  let updateMessageEntry() =
    (match !msg with
      None -> messageEntry#coerce#misc#hide(); helpButton#coerce#misc#hide()
    | Some msg ->
      let (backColor, textColor) = if msg = "0 errors found" then ("green", "black") else ("red", "white") in
      messageEntry#coerce#misc#show();
      messageEntry#set_text msg;
      messageEntry#coerce#misc#modify_base [`NORMAL, `NAME backColor];
      messageEntry#coerce#misc#modify_text [`NORMAL, `NAME textColor]);
    (match !url with
      None -> helpButton#coerce#misc#hide();
    | Some(_) -> helpButton#coerce#misc#show();
    )
  in
  let load tab newPath =
    try
      let chan = open_in_bin newPath in
      let rec iter () =
        let buf = String.create 60000 in
        let result = input chan buf 0 60000 in
        if result = 0 then [] else (String.sub buf 0 result)::iter()
      in
      let chunks = iter() in
      let text = String.concat "" chunks in
      let mtime = in_channel_last_modification_time chan in
      close_in chan;
      let text = file_to_utf8 text in
      let (eol, text) = normalize_to_lf text in
      ignore_text_changes := true;
      let buffer = tab#buffer in
      buffer#delete ~start:buffer#start_iter ~stop:buffer#end_iter;
      let gIter = buffer#start_iter in
      tab#eol := eol;
      (buffer: GSourceView2.source_buffer)#insert ~iter:gIter text;
      let {file_opt_tab_size=tabSize} = get_file_options text in
      tab#mainView#view#set_tab_width tabSize;
      tab#subView#view#set_tab_width tabSize;
      ignore_text_changes := false;
      tab#undoList := [];
      tab#redoList := [];
      buffer#set_modified false;
      let thePath = Filename.concat (Filename.dirname newPath) (Filename.basename newPath) in
      tab#path := Some (thePath, mtime);
      perform_syntax_highlighting tab buffer#start_iter buffer#end_iter;
      updateBufferTitle tab;
      Some thePath
    with Sys_error msg -> GToolbox.message_box "VeriFast IDE" ("Could not load file: " ^ msg); None
  in
  let open_path path =
    let tab = add_buffer () in
    ignore $. load tab path;
    updateBufferMenu ();
    tab
  in
  let new_buffer () =
    let tab = add_buffer () in
    updateBufferMenu ();
    tab
  in
  begin
    let tab = match initialPath with None -> new_buffer () | Some path -> open_path path in
    set_current_tab (Some tab)
  end;
  let store tab thePath =
    let chan = open_out_bin thePath in
    let text = (tab#buffer: GSourceView2.source_buffer)#get_text () in
    output_string chan (utf8_to_file (convert_eol !(tab#eol) text));
    flush chan;
    let mtime = out_channel_last_modification_time chan in
    close_out chan;
    tab#path := Some (thePath, mtime);
    tab#buffer#set_modified false;
    updateBufferTitle tab;
    Some thePath
  in
  let rec saveAs tab =
    match GToolbox.select_file ~title:"Save" () with
      None -> None
    | Some thePath ->
      if Sys.file_exists thePath then
        match GToolbox.question_box ~title:"VeriFast" ~buttons:["Yes"; "No"; "Cancel"] "The file already exists. Overwrite?" with
          1 -> store tab thePath
        | 2 -> saveAs tab
        | _ -> None
      else
        store tab thePath
  in
  let save_core tab thePath mtime =
    if file_has_changed thePath mtime then begin
      match GToolbox.question_box ~title:thePath ~buttons:["Save As"; "Overwrite"; "Cancel"] "This file has been modified by another program." with
        1 -> saveAs tab
      | 2 -> store tab thePath
      | 3 -> None
      | _ -> failwith "cannot happen"
    end else
      store tab thePath
  in
  let save tab =
    match !(tab#path) with
      None -> saveAs tab
    | Some (thePath, mtime) ->
      save_core tab thePath mtime
  in
  let bottomTable = GPack.paned `HORIZONTAL () in
  let bottomTable2 = GPack.paned `HORIZONTAL () in
  let _ = bottomTable#pack2 ~resize:true ~shrink:true (bottomTable2#coerce) in
  let _ = rootTable#pack2 ~resize:true ~shrink:true (bottomTable#coerce) in
  let create_steplistbox =
    let collist = new GTree.column_list in
    let col_k = collist#add Gobject.Data.int in
    let col_text = collist#add Gobject.Data.string in
    let store = GTree.tree_store collist in
    let scrollWin = GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN () in
    let lb = GTree.view ~model:store ~packing:scrollWin#add () in
    lb#coerce#misc#modify_font_by_name !scaledTraceFont;
    let col = GTree.view_column ~title:"Steps" ~renderer:(GTree.cell_renderer_text [], ["text", col_text]) () in
    let _ = lb#append_column col in
    (scrollWin, lb, col_k, col_text, col, store)
  in
  let create_listbox title =
    let collist = new GTree.column_list in
    let col_k = collist#add Gobject.Data.int in
    let col_text = collist#add Gobject.Data.string in
    let store = GTree.list_store collist in
    let scrollWin = GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN () in
    let lb = GTree.view ~model:store ~packing:scrollWin#add () in
    lb#coerce#misc#modify_font_by_name !scaledTraceFont;
    let col = GTree.view_column ~title:title ~renderer:(GTree.cell_renderer_text [], ["text", col_text]) () in
    let _ = lb#append_column col in
    (scrollWin, lb, col_k, col_text, col, store)
  in
  let create_assoc_list_box title1 title2 =
    let collist = new GTree.column_list in
    let col_k = collist#add Gobject.Data.int in
    let col_text1 = collist#add Gobject.Data.string in
    let col_text2 = collist#add Gobject.Data.string in
    let store = GTree.list_store collist in
    let scrollWin = GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN () in
    let lb = GTree.view ~model:store ~packing:scrollWin#add () in
    lb#coerce#misc#modify_font_by_name !scaledTraceFont;
    let col1 = GTree.view_column ~title:title1 ~renderer:(GTree.cell_renderer_text [`FONT !codeFont], ["text", col_text1]) () in
    col1#set_resizable true;
    lb#append_column col1;
    let col2 = GTree.view_column ~title:title2 ~renderer:(GTree.cell_renderer_text [], ["text", col_text2]) () in
    lb#append_column col2;
    (scrollWin, lb, col_k, col_text1, col_text2, col1, col2, store)
  in
  let (steplistFrame, stepList, stepKCol, stepCol, stepViewCol, stepStore) = create_steplistbox in
  let _ = bottomTable#pack1 ~resize:true ~shrink:true (steplistFrame#coerce) in
  let (assumptionsFrame, assumptionsList, assumptionsKCol, assumptionsCol, _, assumptionsStore) = create_listbox "Assumptions" in
  let _ = bottomTable2#pack1 ~resize:true ~shrink:true (assumptionsFrame#coerce) in
  let (chunksFrame, chunksList, chunksKCol, chunksCol, _, chunksStore) = create_listbox "Heap chunks" in
  let _ = bottomTable2#pack2 ~resize:true ~shrink:true (chunksFrame#coerce) in
  let (srcEnvFrame, srcEnvList, srcEnvKCol, srcEnvCol1, srcEnvCol2, _, _, srcEnvStore) = create_assoc_list_box "Local" "Value" in
  let _ = srcPaned#pack2 ~resize:true ~shrink:true (srcEnvFrame#coerce) in
  let (subEnvFrame, subEnvList, subEnvKCol, subEnvCol1, subEnvCol2, _, _, subEnvStore) = create_assoc_list_box "Local" "Value" in
  let _ = subPaned#pack2 ~resize:true ~shrink:true (subEnvFrame#coerce) in
  let setTraceFont fontName =
    traceFont := fontName;
    let scaledFont = getScaledFont fontName in
    scaledTraceFont := scaledFont;
    let setFont widget = widget#coerce#misc#modify_font_by_name scaledFont in
    setFont stepList;
    setFont assumptionsList;
    setFont chunksList;
    setFont srcEnvList;
    setFont subEnvList;
    setFont messageEntry
  in
  let setFontScalePower power =
    fontScalePower := power;
    setCodeFont !codeFont;
    setTraceFont !traceFont
  in
  ignore $. (actionGroup#get_action "TextLarger")#connect#activate (fun () -> setFontScalePower (!fontScalePower + 1));
  ignore $. (actionGroup#get_action "TextSmaller")#connect#activate (fun () -> setFontScalePower (!fontScalePower - 1));
  ignore $. (actionGroup#get_action "TextSizeDefault")#connect#activate (fun () -> setFontScalePower 0);
  let get_tab_for_path path0 =
    (* This function is called only at a time when no buffers are modified. *)
    let rec iter k tabs =
      match tabs with
        tab::tabs ->
        begin match !(tab#path) with Some (path1, mtime) when path1 = path0 -> (k, tab) | _ -> iter (k + 1) tabs end
      | [] ->
        let tab = open_path path0 in (k, tab)
    in
    iter 0 !buffers
  in
  let create_marks_of_loc ((p1, p2): loc) =
    let ((path1_base, path1_relpath) as path1, line1, col1) = p1 in
    let (path2, line2, col2) = p2 in
    assert (path1 = path2);
    let (_, tab) = get_tab_for_path (Filename.concat path1_base path1_relpath) in
    let buffer = tab#buffer in
    let mark1 = buffer#create_mark (srcpos_iter buffer (line1, col1)) in
    let mark2 = buffer#create_mark (srcpos_iter buffer (line2, col2)) in
    (tab, mark1, mark2)
  in
  let stepItems = ref None in
  let clearStepItems() =
    match !stepItems with
      None -> ()
    | Some items ->
      List.iter
        begin fun (ass, h, env, (tab, mark1, mark2), msg, locstack) ->
          let buffer = tab#buffer in
          buffer#delete_mark (`MARK mark1);
          buffer#delete_mark (`MARK mark2)
        end
        items;
      stepItems := None
  in
  let updateStepItems() =
    clearStepItems();
    let ctxts_fifo = List.rev (get !ctxts_lifo) in
    let rec iter k itstack last_it ass locstack last_loc last_env ctxts =
      match ctxts with
        [] -> []
      | Assuming t::cs -> iter k itstack last_it (t::ass) locstack last_loc last_env cs
      | Executing (h, env, l, msg)::cs ->
        let it = stepStore#append ?parent:(match itstack with [] -> None | it::_ -> Some it) () in
        stepStore#set ~row:it ~column:stepKCol k;
        stepStore#set ~row:it ~column:stepCol msg;
        let l = create_marks_of_loc l in
        (ass, h, env, l, msg, locstack)::iter (k + 1) itstack (Some it) ass locstack (Some l) (Some env) cs
      | PushSubcontext::cs ->
        (match (last_it, last_loc, last_env) with (Some it, Some l, Some env) -> iter k (it::itstack) None ass ((l, env)::locstack) None None cs)
      | PopSubcontext::cs ->
        (match (itstack, locstack) with (_::itstack, _::locstack) -> iter k itstack None ass locstack None None cs)
    in
    stepItems := Some (iter 0 [] None [] [] None None ctxts_fifo)
  in
  let append_items (store:GTree.list_store) kcol col items =
    let rec iter k items =
      match items with
        [] -> ()
      | item::items ->
        let gIter = store#append() in
        store#set ~row:gIter ~column:kcol k;
        store#set ~row:gIter ~column:col item;
        iter (k + 1) items
    in
    iter 0 items
  in
  let append_assoc_items (store:GTree.list_store) kcol col1 col2 items =
    let rec iter k items =
      match items with
        [] -> ()
      | (item1, item2)::items ->
        let gIter = store#append() in
        store#set ~row:gIter ~column:kcol k;
        store#set ~row:gIter ~column:col1 item1;
        store#set ~row:gIter ~column:col2 item2;
        iter (k + 1) items
    in
    iter 0 items
  in
  let clearStepInfo() =
    List.iter (fun tab ->
      let buffer = tab#buffer in
      buffer#remove_tag_by_name "currentLine" ~start:buffer#start_iter ~stop:buffer#end_iter;
      buffer#remove_tag_by_name "currentCaller" ~start:buffer#start_iter ~stop:buffer#end_iter
    ) !buffers;
    assumptionsStore#clear();
    chunksStore#clear();
    srcEnvStore#clear();
    subEnvStore#clear()
  in
  let apply_tag_at_marks name (tab, mark1, mark2) =
    let buffer = tab#buffer in
    buffer#apply_tag_by_name name ~start:(buffer#get_iter_at_mark (`MARK mark1)) ~stop:(buffer#get_iter_at_mark (`MARK mark2))
  in
  let apply_tag_by_loc name ((p1, p2): loc) =
    let ((path1_base, path1_relpath) as path1, line1, col1) = p1 in
    let (path2, line2, col2) = p2 in
    assert (path1 = path2);
    let (_, tab) = get_tab_for_path (Filename.concat path1_base path1_relpath) in
    let buffer = tab#buffer in
    buffer#apply_tag_by_name name ~start:(srcpos_iter buffer (line1, col1)) ~stop:(srcpos_iter buffer (line2, col2))
  in
  let get_step_of_path selpath =
    let stepItems = match !stepItems with Some stepItems -> stepItems | None -> assert false in
    let k = let gIter = stepStore#get_iter selpath in stepStore#get ~row:gIter ~column:stepKCol in
    List.nth stepItems k
  in
  let strings_of_env env =
    let env = remove_dups env in
    let compare_bindings (x1, v1) (x2, v2) = compare x1 x2 in
    let env = List.sort compare_bindings env in
    List.filter (fun entry -> entry <> ("currentThread", "currentThread")) env
  in
  let stepSelected _ =
    match !stepItems with
      None -> ()
    | Some stepItems ->
      clearStepInfo();
      let selpath = List.hd stepList#selection#get_selected_rows in
      let (ass, h, env, l, msg, locstack) = get_step_of_path selpath in
      begin
        match locstack with
          [] ->
          if textPaned#max_position - textPaned#position < 10 then
            textPaned#set_position 0;
          apply_tag_at_marks "currentLine" l;
          let (tab, mark1, _) = l in
          goto_tab tab;
          tab#buffer#move_mark (`MARK tab#currentStepMark) ~where:(tab#buffer#get_iter_at_mark (`MARK mark1));
          ignore $. Glib.Idle.add(fun () -> tab#mainView#view#scroll_to_mark ~within_margin:0.2 (`MARK tab#currentStepMark); false);
          append_assoc_items srcEnvStore srcEnvKCol srcEnvCol1 srcEnvCol2 (strings_of_env env)
        | (caller_loc, caller_env)::_ ->
          if textPaned#max_position >= 300 && textPaned#position < 10 || textPaned#max_position - textPaned#position < 10 then
            textPaned#set_position 150;
          begin
            apply_tag_at_marks "currentLine" l;
            let (tab, mark1, _) = l in
            let k = index_of_byref tab !buffers in
            subNotebook#goto_page k;
            tab#buffer#move_mark (`MARK tab#currentStepMark) ~where:(tab#buffer#get_iter_at_mark (`MARK mark1));
            ignore $. Glib.Idle.add (fun () -> tab#subView#view#scroll_to_mark ~within_margin:0.2 (`MARK tab#currentStepMark); false); 
            append_assoc_items subEnvStore subEnvKCol subEnvCol1 subEnvCol2 (strings_of_env env)
          end;
          begin
            apply_tag_at_marks "currentCaller" caller_loc;
            let (tab, mark1, _) = caller_loc in
            goto_tab tab;
            tab#buffer#move_mark (`MARK tab#currentCallerMark) ~where:(tab#buffer#get_iter_at_mark (`MARK mark1));
            ignore $. Glib.Idle.add(fun () -> tab#mainView#view#scroll_to_mark ~within_margin:0.2 (`MARK tab#currentCallerMark); false);
            append_assoc_items srcEnvStore srcEnvKCol srcEnvCol1 srcEnvCol2 (strings_of_env caller_env)
          end
      end;
      append_items assumptionsStore assumptionsKCol assumptionsCol (List.rev ass);
      let compare_chunks (Chunk ((g, literal), targs, coef, ts, size)) (Chunk ((g', literal'), targs', coef', ts', size')) =
        let r = compare g g' in
        if r <> 0 then r else
        let rec compare_list xs ys =
          match (xs, ys) with
            ([], []) -> 0
          | (x::xs, y::ys) ->
            let r = compare x y in
            if r <> 0 then r else compare_list xs ys
        in
        let r = compare (Verifast.string_of_targs targs) (Verifast.string_of_targs targs') in
        if r <> 0 then r else
        let r = compare_list ts ts' in
        if r <> 0 then r else
        compare coef coef'
      in
      append_items chunksStore chunksKCol chunksCol (List.map Verifast.string_of_chunk (List.sort compare_chunks h))
  in
  let _ = stepList#connect#cursor_changed ~callback:stepSelected in
  let _ = (new GObj.misc_ops stepList#as_widget)#grab_focus() in
  let get_last_step_path() =
    let lastBigStep = stepStore#iter_children ~nth:(stepStore#iter_n_children None - 1) None in
    let lastBigStepChildCount = stepStore#iter_n_children (Some lastBigStep) in
    let lastStep = if lastBigStepChildCount > 0 then stepStore#iter_children ~nth:(lastBigStepChildCount - 1) (Some lastBigStep) else lastBigStep in
    stepStore#get_path lastStep
  in
  let updateStepListView() =
    stepList#expand_all();
    let lastStepRowPath = get_last_step_path() in
    let _ = stepList#selection#select_path lastStepRowPath in
    Glib.Idle.add (fun () -> stepList#scroll_to_cell lastStepRowPath stepViewCol; false)
  in
  let ensureSaved tab =
    if tab#buffer#modified then
      match GToolbox.question_box ~title:"VeriFast" ~buttons:["Save"; "Discard"; "Cancel"] "There are unsaved changes." with
        1 -> (match save tab with None -> true | Some _ -> false)
      | 2 -> false
      | _ -> true
    else
      false
  in
  let _ = root#connect#destroy ~callback:GMain.Main.quit in
  let clearTrace() =
    if !msg <> None then
    begin
      msg := None;
      url := None;
      clearStepItems();
      updateMessageEntry();
      clearStepInfo();
      stepStore#clear();
      List.iter (fun tab ->
        let buffer = tab#buffer in
        buffer#remove_tag_by_name "error" ~start:buffer#start_iter ~stop:buffer#end_iter
      ) !buffers
    end
  in
  bufferChangeListener := (fun tab ->
    ()
  );
  ignore $. root#event#connect#delete ~callback:(fun _ ->
    let rec iter tabs =
      match tabs with
        [] -> false
      | tab::tabs -> ensureSaved tab || iter tabs
    in
    iter !buffers
  );
  let get_current_tab() =
    match !current_tab with
      Some tab -> Some tab
    | None -> GToolbox.message_box "VeriFast IDE" ("Please select a buffer."); None
  in
  let close tab =
    (* Returns true if canceled *)
    ensureSaved tab ||
    begin
      clearTrace();
      textNotebook#remove tab#mainView#page#coerce;
      subNotebook#remove tab#subView#page#coerce;
      buffers := List.filter (fun tab0 -> not (tab0 == tab)) !buffers;
      begin match !current_tab with None -> () | Some tab0 -> if tab == tab0 then set_current_tab None end;
      updateBufferMenu ();
      false
    end
  in
  let rec close_all () =
    (* Returns true if canceled *)
    match !buffers with
      [] -> false
    | tab::_ ->
      close tab || close_all ()
  in
  ignore $. (actionGroup#get_action "New")#connect#activate (fun _ ->
    ignore (close_all () || (ignore $. new_buffer (); false))
  );
  ignore $. (actionGroup#get_action "Open")#connect#activate (fun _ ->
    match GToolbox.select_file ~title:"Open" () with
      None -> ()
    | Some thePath ->
      if not (close_all ()) then
      ignore (open_path thePath)
  );
  ignore $. (actionGroup#get_action "Save")#connect#activate (fun () -> match get_current_tab() with Some tab -> ignore $. save tab | None -> ());
  ignore $. (actionGroup#get_action "SaveAs")#connect#activate (fun () -> match get_current_tab() with Some tab -> ignore $. saveAs tab | None -> ());
  ignore $. (actionGroup#get_action "Close")#connect#activate (fun () -> match get_current_tab() with Some tab -> ignore $. close tab | None -> ());
  let go_to_loc l =
    let (start, stop) = l in
    let (path, line, col) = start in
    let (k, tab) = get_tab_for_path (string_of_path path) in
    textNotebook#goto_page k;
    let buffer = tab#buffer in
    let it = srcpos_iter buffer (line, col) in
    buffer#place_cursor ~where:it;
    ignore $. Glib.Idle.add (fun () -> ignore $. tab#mainView#view#scroll_to_iter ~within_margin:0.2 it; (* NOTE: scroll_to_iter returns a boolean *) false);
    ()
  in
  let handleStaticError l emsg eurl =
    apply_tag_by_loc "error" l;
    msg := Some emsg;
    url := eurl;
    updateMessageEntry();
    go_to_loc l
  in
  let loc_path ((path, _, _), _) = path in
  let reportRange kind l =
    apply_tag_by_loc (tag_name_of_range_kind kind) l
  in
  let reportUseSite declKind declLoc useSiteLoc =
    let (useSiteStart, useSiteStop) = useSiteLoc in
    let (useSitePath, useSiteLine, useSiteCol) = useSiteStart in
    let (_, useSiteStopLine, useSiteStopCol) = useSiteStop in
    let (useSiteK, useSiteTab) = get_tab_for_path (string_of_path useSitePath) in
    let useSiteBuffer = useSiteTab#buffer in
    let useSiteTag = useSiteBuffer#create_tag [] in
    useSiteTab#useSiteTags := useSiteTag::!(useSiteTab#useSiteTags);
    ignore $. useSiteTag#connect#event begin fun ~origin event iter ->
      if GdkEvent.get_type event = `KEY_PRESS then begin
        let key = GdkEvent.Key.cast event in
        if GdkEvent.Key.keyval key = GdkKeysyms._d && List.mem `CONTROL (GdkEvent.Key.state key) then
          go_to_loc declLoc
      end;
      false
    end;
    useSiteBuffer#apply_tag useSiteTag ~start:(srcpos_iter useSiteBuffer (useSiteLine, useSiteCol)) ~stop:(srcpos_iter useSiteBuffer (useSiteStopLine, useSiteStopCol))
  in
  let ensureHasPath tab =
    match !(tab#path) with
      None -> save tab
    | Some (path, mtime) ->
      if tab#buffer#modified then
        save_core tab path mtime
      else if file_has_changed path mtime then begin
       print_endline (Printf.sprintf "File '%s' has been changed by another program; reloading from disk..." path);
       load tab path
      end else
        Some path
  in
  let undo () =
    match get_current_tab() with
      None -> ()
    | Some tab ->
      let buffer = tab#buffer in
      begin
        match !(tab#undoList) with
          [] -> ()
        | ac::acs ->
          ignore_text_changes := true;
          let offset =
            match ac with
              Insert (offset, text) ->
              let start = buffer#get_iter (`OFFSET offset) in
              let stop = buffer#get_iter (`OFFSET (offset + String.length text)) in
              buffer#delete ~start:start ~stop:stop;
              offset
            | Delete (offset, text) ->
              let start = buffer#get_iter (`OFFSET offset) in
              buffer#insert ~iter:start text;
              offset + String.length text
          in
          ignore_text_changes := false;
          tab#undoList := acs;
          tab#redoList := ac::!(tab#redoList);
          undoAction#set_sensitive (acs <> []);
          redoAction#set_sensitive true;
          buffer#place_cursor ~where:(buffer#get_iter (`OFFSET offset));
          tab#mainView#view#scroll_to_mark ~within_margin:0.2 `INSERT 
      end
  in
  let redo () =
    match get_current_tab() with
      None -> ()
    | Some tab ->
      let buffer = tab#buffer in
      begin
        match !(tab#redoList) with
          [] -> ()
        | ac::acs ->
          ignore_text_changes := true;
          let offset =
            match ac with
              Insert (offset, text) ->
              let start = buffer#get_iter (`OFFSET offset) in
              buffer#insert ~iter:start text;
              offset + String.length text
            | Delete (offset, text) ->
              let start = buffer#get_iter (`OFFSET offset) in
              let stop = buffer#get_iter (`OFFSET (offset + String.length text)) in
              buffer#delete ~start:start ~stop:stop;
              offset
          in
          ignore_text_changes := false;
          tab#redoList := acs;
          tab#undoList := ac::!(tab#undoList);
          undoAction#set_sensitive true;
          redoAction#set_sensitive (acs <> []);
          buffer#place_cursor ~where:(buffer#get_iter (`OFFSET offset));
          tab#mainView#view#scroll_to_mark ~within_margin:0.2 `INSERT
      end
  in
  let sync_with_disk tab =
    (* Ensure the buffer contents are equal to the file contents. Returns true on cancellation. *)
    match !(tab#path) with
      None -> false
    | Some (path, mtime) ->
      if tab#buffer#modified then
        match save_core tab path mtime with Some _ -> false | None -> true
      else
        file_has_changed path mtime && close tab
  in
  let clearSyntaxHighlighting () =
    !buffers |> List.iter begin fun tab ->
      let buffer = tab#buffer in
      buffer#remove_all_tags ~start:buffer#start_iter ~stop:buffer#end_iter;
      let tagTable = new GText.tag_table buffer#tag_table in
      !(tab#useSiteTags) |> List.iter (fun tag -> tagTable#remove tag#as_tag);
      tab#useSiteTags := []
    end
  in
  let verifyProgram runToCursor () =
    clearTrace();
    match !buffers with
      [] -> ()
    | tab::tabs ->
      begin
        match ensureHasPath tab with
          None -> ()
        | Some path ->
          clearSyntaxHighlighting();
          if not (List.exists sync_with_disk tabs) then
          begin
            let breakpoint =
              if runToCursor then
              begin match !current_tab with
                None -> None
              | Some tab ->
                match !(tab#path) with
                  None -> None
                | Some (path, mtime) ->
                  let buffer = tab#buffer in
                  let insert_iter = buffer#get_iter_at_mark `INSERT in
                  let insert_line = insert_iter#line in
                  Some (path, insert_line + 1)
              end
              else
                None
            in
            try
              let options = {
                option_verbose = 0;
                option_disable_overflow_check = !disableOverflowCheck;
                option_allow_should_fail = true;
                option_emit_manifest = false;
                option_allow_assume = true;
                option_simplify_terms = !simplifyTerms;
                option_runtime = runtime
              }
              in
              verify_program prover false options path reportRange reportUseSite breakpoint;
              msg := Some (if runToCursor then "0 errors found (cursor is unreachable)" else "0 errors found");
              updateMessageEntry()
            with
              ParseException (l, emsg) ->
              handleStaticError l ("Parse error" ^ (if emsg = "" then "." else ": " ^ emsg)) None
            | CompilationError(emsg) ->
              clearTrace();
              msg := Some(emsg);
              updateMessageEntry()
            | StaticError (l, emsg, eurl) ->
              handleStaticError l emsg eurl 
            | SymbolicExecutionError (ctxts, phi, l, emsg, eurl) ->
              ctxts_lifo := Some ctxts;
              updateStepItems();
              ignore $. updateStepListView();
              stepSelected();
              (* let (ass, h, env, steploc, stepmsg, locstack) = get_step_of_path (get_last_step_path()) in *)
              begin match ctxts with
                Executing (_, _, steploc, _)::_ when l = steploc ->
                apply_tag_by_loc "error" l;
                msg := Some emsg;
                url := eurl;
                updateMessageEntry()
              | _ ->
                handleStaticError l emsg eurl
              end
            | e ->
              prerr_endline ("VeriFast internal error: " ^ Printexc.to_string e);
              Printexc_proxy.print_backtrace stderr;
              flush stderr;
              GToolbox.message_box "VeriFast IDE" "Verification failed due to an internal error. See the console window for details."
          end
      end
  in
  let showPreferencesDialog () =
    let dialog = GWindow.dialog ~title:"Preferences" ~parent:root () in
    let vbox = dialog#vbox in
    let itemsTable = GPack.table ~rows:2 ~columns:2 ~border_width:4 ~row_spacings:4 ~col_spacings:4 ~packing:(vbox#pack ~from:`START ~expand:true) () in
    ignore $. GMisc.label ~text:"Code font:" ~packing:(itemsTable#attach ~left:0 ~top:0 ~expand:`X) ();
    let codeFontButton = GButton.font_button ~font_name:!codeFont ~show:true ~packing:(itemsTable#attach ~left:1 ~top:0 ~expand:`X) () in
    ignore $. GMisc.label ~text:"Trace font:" ~packing:(itemsTable#attach ~left:0 ~top:1 ~expand:`X) ();
    let traceFontButton = GButton.font_button ~font_name:!traceFont ~show:true ~packing:(itemsTable#attach ~left:1 ~top:1 ~expand:`X) () in
    let okButton = GButton.button ~stock:`OK ~packing:dialog#action_area#add () in
    ignore $. okButton#connect#clicked (fun () ->
      setCodeFont codeFontButton#font_name;
      setTraceFont traceFontButton#font_name;
      dialog#response `DELETE_EVENT
    );
    let cancelButton = GButton.button ~stock:`CANCEL ~packing:dialog#action_area#add () in
    ignore $. cancelButton#connect#clicked (fun () -> dialog#response `DELETE_EVENT);
    ignore $. dialog#run();
    dialog#destroy()
  in
  ignore $. (actionGroup#get_action "ClearTrace")#connect#activate clearTrace;
  ignore $. (actionGroup#get_action "Preferences")#connect#activate showPreferencesDialog;
  ignore $. (actionGroup#get_action "VerifyProgram")#connect#activate (verifyProgram false);
  ignore $. (actionGroup#get_action "RunToCursor")#connect#activate (verifyProgram true);
  ignore $. undoAction#connect#activate undo;
  ignore $. redoAction#connect#activate redo;
  ignore $. root#event#connect#focus_in begin fun _ ->
    !buffers |> List.iter begin fun tab ->
      match !(tab#path) with
        None -> ()
      | Some (path, mtime) ->
        if not tab#buffer#modified && Sys.file_exists path && file_has_changed path mtime then begin
          print_endline (Printf.sprintf "File '%s' has been changed by another program; reloading from disk..." path);
          ignore (load tab path)
        end
    end;
    false
  end;
  root#show();
  ignore $. Glib.Idle.add (fun () -> textPaned#set_position 0; false);
  GMain.main()

let () =
  let path = ref None in
  let prover = ref None in
  let codeFont = ref Fonts.code_font in
  let traceFont = ref Fonts.trace_font in
  let runtime = ref None in
  let rec iter args =
    match args with
      "-prover"::arg::args -> prover := Some arg; iter args
    | "-codeFont"::arg::args -> codeFont := arg; iter args
    | "-traceFont"::arg::args -> traceFont := arg; iter args
    | "-runtime"::arg::args -> runtime := Some arg; iter args
    | arg::args when not (startswith arg "-") -> path := Some arg; iter args
    | [] -> show_ide !path !prover !codeFont !traceFont !runtime
    | _ -> GToolbox.message_box "VeriFast IDE" "Invalid command line.\n\nUsage: vfide [filepath] [-prover z3|redux] [-codeFont fontSpec] [-traceFont fontSpec]"
  in
  let _::args = Array.to_list (Sys.argv) in
  iter args
