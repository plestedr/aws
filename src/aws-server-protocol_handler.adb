------------------------------------------------------------------------------
--                              Ada Web Server                              --
--                                                                          --
--                         Copyright (C) 2000-2001                          --
--                                ACT-Europe                                --
--                                                                          --
--  Authors: Dmitriy Anisimkov - Pascal Obry                                --
--                                                                          --
--  This library is free software; you can redistribute it and/or modify    --
--  it under the terms of the GNU General Public License as published by    --
--  the Free Software Foundation; either version 2 of the License, or (at   --
--  your option) any later version.                                         --
--                                                                          --
--  This library is distributed in the hope that it will be useful, but     --
--  WITHOUT ANY WARRANTY; without even the implied warranty of              --
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU       --
--  General Public License for more details.                                --
--                                                                          --
--  You should have received a copy of the GNU General Public License       --
--  along with this library; if not, write to the Free Software Foundation, --
--  Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.          --
--                                                                          --
--  As a special exception, if other files instantiate generics from this   --
--  unit, or you link this unit with other files to produce an executable,  --
--  this  unit  does not  by itself cause  the resulting executable to be   --
--  covered by the GNU General Public License. This exception does not      --
--  however invalidate any other reasons why the executable file  might be  --
--  covered by the  GNU Public License.                                     --
------------------------------------------------------------------------------

--  $RCSfile$
--  $Revision$
--  $Date$
--  $Author$

--  This procedure is responsible to treat the HTTP protocol. Every responses
--  and coming requests are parsed/formated here.

with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;

with Templates_Parser;

with AWS.Config;
with AWS.Digest;
with AWS.Log;
with AWS.Messages;
with AWS.MIME;
with AWS.OS_Lib;
with AWS.Parameters.Set;
with AWS.Resources;
with AWS.Session;
with AWS.Server.Get_Status;
with AWS.Status.Set;
with AWS.Translator;
with AWS.Utils;
with AWS.URL;

separate (AWS.Server)

procedure Protocol_Handler
  (HTTP_Server : in out HTTP;
   Index       : in     Positive)
is

   use Ada;
   use Ada.Strings;
   use Ada.Strings.Unbounded;

   Case_Sensitive_Parameters : constant Boolean
     := CNF.Case_Sensitive_Parameters (HTTP_Server.Properties);

   Admin_URI      : constant String
     := CNF.Admin_URI (HTTP_Server.Properties);

   End_Of_Message : constant String := "";
   HTTP_10        : constant String := "HTTP/1.0";

   C_Stat         : AWS.Status.Data;     -- Connection status
   P_List         : AWS.Parameters.List; -- Form data

   Sock           : Sockets.Socket_FD'Class
     renames HTTP_Server.Slots.Get (Index => Index).Sock.all;

   Socket_Taken   : Boolean := False;
   --  Set to True if a socket has been reserved for a push session.

   Will_Close     : Boolean;
   --  Will_Close is set to true when the connection will be closed by the
   --  server. It means that the server is about to send the lastest message
   --  to the client using this sockets.

   procedure Parse (Command : in String);
   --  Parse a line sent by the client and do what is needed

   procedure Send_File
     (Filename     : in String;
      File_Size    : in Natural;
      HTTP_Version : in String);
   --  Send content of filename as chunk data

   procedure Answer_To_Client;
   --  This procedure use the C_Stat status data to send the correct answer
   --  to the client.

   procedure Get_Message_Header;
   --  Parse HTTP message header. This procedure fill in the C_Stat status
   --  data.

   procedure Get_Message_Data;
   --  If the client sent us some data read them. Right now only the
   --  POST method is handled. This procedure fill in the C_Stat status
   --  data.

   procedure Parse_Request_Line (Command : in String);
   --  Parse the request line:
   --  Request-Line = Method SP Request-URI SP HTTP-Version CRLF

   procedure Send_File_Time
     (Sock     : in Sockets.Socket_FD'Class;
      Filename : in String);
   --  Send Last-Modified: header for the filename.

   function Is_Valid_HTTP_Date (HTTP_Date : in String) return Boolean;
   --  Check the date format as some Web brower seems to return invalid date
   --  field.

   ----------------------
   -- Answer_To_Client --
   ----------------------

   procedure Answer_To_Client is

      use type Messages.Status_Code;
      use type Response.Data_Mode;

      Answer : Response.Data;

      Status : Messages.Status_Code;

      procedure Create_Session;
      --  Create a session if needed

      procedure Send_General_Header;
      --  Send the "Date:", "Server:", "Set-Cookie:" and "Connection:" header.

      procedure Send_Header_Only;
      --  Send HTTP message header only. This is used to implement the HEAD
      --  request.

      procedure Send_File;
      --  Send a text/binary file to the client.

      procedure Send_Message;
      --  Answer is a text or HTML message.

      procedure Answer_File (File_Name : in String);
      --  Assign File to Answer response data.

      -----------------
      -- Answer_File --
      -----------------

      procedure Answer_File (File_Name : in String) is
      begin
         Answer := Response.File
           (Content_Type => MIME.Content_Type (File_Name),
            Filename     => File_Name);
      end Answer_File;

      --------------------
      -- Create_Session --
      --------------------

      procedure Create_Session is
         use type Session.ID;
      begin
         if CNF.Session (HTTP_Server.Properties)
           and then (AWS.Status.Session (C_Stat) = Session.No_Session
                     or else not Session.Exist (AWS.Status.Session (C_Stat)))
         then
            --  Generate the session ID
            AWS.Status.Set.Session (C_Stat);
         end if;
      end Create_Session;

      ---------------
      -- Send_File --
      ---------------

      procedure Send_File is
         use type Calendar.Time;
         use type AWS.Status.Request_Method;

         Filename      : constant String := Response.Filename (Answer);
         Is_Up_To_Date : Boolean;

      begin
         Is_Up_To_Date :=
           Is_Valid_HTTP_Date (AWS.Status.If_Modified_Since (C_Stat))
            and then
           Resources.File_Timestamp (Filename)
            = Messages.To_Time (AWS.Status.If_Modified_Since (C_Stat));
         --  Equal used here see [RFC 2616 - 14.25]

         if Is_Up_To_Date then
            --  [RFC 2616 - 10.3.5]
            Sockets.Put_Line (Sock,
                              Messages.Status_Line (Messages.S304));
            Send_General_Header;
            Sockets.New_Line (Sock);
            return;
         else
            Sockets.Put_Line (Sock, Messages.Status_Line (Status));
         end if;

         Send_General_Header;

         Sockets.Put_Line
           (Sock, Messages.Content_Type (Response.Content_Type (Answer)));

         --  Send message body only if needed

         if AWS.Status.Method (C_Stat) = AWS.Status.HEAD then
            --  Send file info and terminate header

            Send_File_Time (Sock, Filename);

            Sockets.Put_Line
              (Sock,
               Messages.Content_Length (Response.Content_Length (Answer)));
            Sockets.New_Line (Sock);

         else
            Send_File (Filename,
                       Response.Content_Length (Answer),
                       AWS.Status.HTTP_Version (C_Stat));
         end if;
      end Send_File;

      -------------------------
      -- Send_General_Header --
      -------------------------

      procedure Send_General_Header is
      begin
         --  Session

         if CNF.Session (HTTP_Server.Properties)
           and then AWS.Status.Session_Created (C_Stat)
         then
            --  This is an HTTP connection with session but there is no session
            --  ID set yet. So, send cookie to client browser.

            Sockets.Put_Line
              (Sock,
               "Set-Cookie: AWS="
               & Session.Image (AWS.Status.Session (C_Stat)) & "; path=/");
         end if;

         --  Date

         Sockets.Put_Line
           (Sock,
            "Date: " & Messages.To_HTTP_Date (OS_Lib.GMT_Clock));

         --  Server

         Sockets.Put_Line (Sock,
                           "Server: AWS (Ada Web Server) v" & Version);

         --  Connection

         if Will_Close then
            --  We was deciding to close connection after answer to client.

            Sockets.Put_Line (Sock, Messages.Connection ("close"));
         else
            Sockets.Put_Line
              (Sock,
               Messages.Connection (AWS.Status.Connection (C_Stat)));
         end if;

         --  Handle authentication message

         if Status = Messages.S401 then
            declare
               use Response;
               Authenticate : constant Authentication_Mode
                 := Authentication (Answer);
            begin
               --  In case of Authenticate = Any
               --  We should create both header lines
               --  WWW-Authenticate: Basic
               --  and
               --  WWW-Authenticate: Digest

               if Authenticate = Response.Digest
                 or Authenticate = Any
               then
                  Sockets.Put_Line
                    (Sock,
                     Messages.Www_Authenticate
                       (Realm (Answer),
                        Digest.Create_Nonce,
                        Response.Authentication_Stale (Answer)));
               end if;

               if Authenticate = Basic
                 or Authenticate = Any
               then
                  Sockets.Put_Line
                    (Sock,
                     Messages.Www_Authenticate (Realm (Answer)));
               end if;
            end;
         end if;
      end Send_General_Header;

      ----------------------
      -- Send_Header_Only --
      ----------------------

      procedure Send_Header_Only is
         use type AWS.Status.Request_Method;
      begin
         --  First let's output the status line

         Sockets.Put_Line (Sock, Messages.Status_Line (Status));

         Send_General_Header;

         --  There is no content

         Sockets.Put_Line (Sock, Messages.Content_Length (0));

         --  End of header

         Sockets.New_Line (Sock);
      end Send_Header_Only;

      ------------------
      -- Send_Message --
      ------------------

      procedure Send_Message is
         use type AWS.Status.Request_Method;
      begin
         --  First let's output the status line

         Sockets.Put_Line (Sock, Messages.Status_Line (Status));

         --  Handle redirection

         if Status = Messages.S301 then
            Sockets.Put_Line
              (Sock,
               Messages.Location (Response.Location (Answer)));
         end if;

         Send_General_Header;

         --  Now we output the message body length

         Sockets.Put_Line
           (Sock,
            Messages.Content_Length (Response.Content_Length (Answer)));

         --  The message content type

         Sockets.Put_Line
           (Sock,
            Messages.Content_Type (Response.Content_Type (Answer)));

         --  End of header

         Sockets.New_Line (Sock);

         --  Send message body only if needed

         if AWS.Status.Method (C_Stat) /= AWS.Status.HEAD then

            declare
               use Streams;

               Message_Body   : constant Stream_Element_Array
                 := Response.Message_Body (Answer);

               Message_Length : constant Stream_Element_Offset
                 := Message_Body'Length;

               I          : Stream_Element_Offset := 1;
               I_Next     : Stream_Element_Offset;

               Piece_Size : constant := 16#4000#;
            begin
               Send_Message_Body : loop
                  I_Next := I + Piece_Size;

                  if I_Next > Message_Length then
                     Sockets.Send (Sock, Message_Body (I .. Message_Length));
                     exit Send_Message_Body;
                  else
                     Sockets.Send (Sock, Message_Body (I .. I_Next - 1));
                  end if;

                  HTTP_Server.Slots.Mark_Data_Time_Stamp (Index);
                  I := I_Next;
               end loop Send_Message_Body;
            end;
         end if;
      end Send_Message;

      URI : constant String := AWS.Status.URI (C_Stat);

   begin
      --  Set status peername

      AWS.Status.Set.Peername
        (C_Stat, HTTP_Server.Slots.Get_Peername (Index));

      --  Check if the status page, status page logo or status page images are
      --  requested. These are AWS internal data that should not be handled by
      --  AWS users.

      --  AWS Internal status page handling.

      if Admin_URI'Length > 0
           and then
        URI'Length >= Admin_URI'Length
           and then
        URI (URI'First .. URI'First + Admin_URI'Length - 1) = Admin_URI
      then

         if URI = Admin_URI then

            --  Status page
            begin
               Answer := Response.Build
                 (Content_Type => MIME.Text_HTML,
                  Message_Body => Get_Status (HTTP_Server));
            exception
               when Templates_Parser.Template_Error =>
                  Answer := Response.Build
                    (Content_Type => MIME.Text_HTML,
                     Message_Body =>
                       "Status template error. Please check "
                       & "that '" & CNF.Status_Page (HTTP_Server.Properties)
                       & "' file is valid.");
            end;

         elsif URI = Admin_URI & "-logo" then
            --  Status page logo
            Answer_File (CNF.Logo_Image (HTTP_Server.Properties));

         elsif URI = Admin_URI & "-uparr" then
            --  Status page hotplug up-arrow
            Answer_File (CNF.Up_Image (HTTP_Server.Properties));

         elsif URI = Admin_URI & "-downarr" then
            --  Status page hotplug down-arrow
            Answer_File (CNF.Down_Image (HTTP_Server.Properties));

         elsif URI = Admin_URI & "-HPup" then
            --  Status page hotplug up message
            Hotplug.Move_Up
              (HTTP_Server.Filters,
               Positive'Value (AWS.Parameters.Get (P_List, "N")));
            Answer := Response.URL (Admin_URI);

         elsif URI = Admin_URI & "-HPdown" then
            --  Status page hotplug down message
            Hotplug.Move_Down
              (HTTP_Server.Filters,
               Positive'Value (AWS.Parameters.Get (P_List, "N")));
            Answer := Response.URL (Admin_URI);

         else
            Answer := Response.Build
              (Content_Type => MIME.Text_HTML,
               Message_Body =>
                 "Invalid use of reserved status URI prefix: " & Admin_URI);
         end if;

      --  End of Internal status page handling.

      else
         --  Otherwise, check if a session needs to be created

         Create_Session;

         --  and get answer from client callback

         declare
            Found : Boolean;
         begin
            HTTP_Server.Slots.Mark_Phase (Index, Server_Processing);

            --  Check the hotplug filters

            Hotplug.Apply (HTTP_Server.Filters, C_Stat, Found, Answer);

            --  If no one applied, run the user callback

            if not Found then
               declare
                  Socket : aliased Sockets.Socket_FD'Class := Sock;
               begin
                  AWS.Status.Set.Socket (C_Stat, Socket'Unchecked_Access);

                  Answer := Dispatchers.Dispatch
                    (HTTP_Server.Dispatcher.all, C_Stat);
               end;
            end if;

            HTTP_Server.Slots.Mark_Phase (Index, Server_Response);
         end;
      end if;

      Status := Response.Status_Code (Answer);

      case Response.Mode (Answer) is

         when Response.Message =>
            Send_Message;

         when Response.File =>
            Send_File;

         when Response.Header =>
            Send_Header_Only;

         when Response.Socket_Taken =>
            HTTP_Server.Slots.Socket_Taken (Index);
            Socket_Taken := True;

         when Response.No_Data =>
            null;

      end case;

      AWS.Log.Write (HTTP_Server.Log, C_Stat, Answer);
   end Answer_To_Client;

   ----------------------
   -- Get_Message_Data --
   ----------------------

   procedure Get_Message_Data is

      use type Status.Request_Method;

      procedure File_Upload
        (Start_Boundary, End_Boundary : in String;
         Parse_Boundary               : in Boolean);
      --  Handle file upload data coming from the client browser.

      function Value_For (Name : in String; Into : in String) return String;
      --  Returns the value for the variable named "Name" into the string
      --  "Into". The data format is: name1="value2"; name2="value2"...

      -----------------
      -- File_Upload --
      -----------------

      procedure File_Upload
        (Start_Boundary, End_Boundary : in String;
         Parse_Boundary               : in Boolean)
      is
         --  ??? Implementation would be more efficient if the input socket
         --  stream was buffered. Here the socket is read char by char.

         Name            : Unbounded_String;
         Filename        : Unbounded_String;
         Server_Filename : Unbounded_String;
         Content_Type    : Unbounded_String;
         File            : Streams.Stream_IO.File_Type;
         Is_File_Upload  : Boolean;

         procedure Get_File_Data;
         --  Read file data from the stream.

         function Target_Filename (Filename : in String) return String;
         --  Returns the full path name for the file as stored on the
         --  server side.

         --------------
         -- Get_Data --
         --------------

         procedure Get_File_Data is

            use type Streams.Stream_Element;
            use type Streams.Stream_Element_Offset;
            use type Streams.Stream_Element_Array;

            function Check_EOF return Boolean;
            --  Returns True if we have reach the end of file data.

            function End_Boundary_Signature
              return Streams.Stream_Element_Array;
            --  Returns the end signature string as a element array.

            Buffer : Streams.Stream_Element_Array (1 .. 4096);
            Index  : Streams.Stream_Element_Offset := Buffer'First;

            Data   : Streams.Stream_Element_Array (1 .. 1);

            ---------------
            -- Check_EOF --
            ---------------

            function Check_EOF return Boolean is
               Signature : Streams.Stream_Element_Array :=
                 (1 => 13, 2 => 10) & End_Boundary_Signature;

               Buffer : Streams.Stream_Element_Array (1 .. Signature'Length);
               Index  : Streams.Stream_Element_Offset := Buffer'First;

               procedure Write_Data;
               --  Put buffer data into the main buffer (Get_Data.Buffer). If
               --  the main buffer is not big enough, it will write the buffer
               --  into the file bdefore.

               ----------------
               -- Write_Data --
               ----------------

               procedure Write_Data is
               begin
                  if Get_File_Data.Buffer'Last
                    < Get_File_Data.Index + Index - 1
                  then
                     Streams.Stream_IO.Write
                       (File, Get_File_Data.Buffer
                        (Get_File_Data.Buffer'First
                         .. Get_File_Data.Index - 1));
                     Get_File_Data.Index := Get_File_Data.Buffer'First;
                  end if;

                  Get_File_Data.Buffer (Get_File_Data.Index
                                        .. Get_File_Data.Index + Index - 2)
                    := Buffer (Buffer'First .. Index - 1);
                  Get_File_Data.Index := Get_File_Data.Index + Index - 1;
               end Write_Data;

            begin
               Buffer (Index) := 13;
               Index := Index + 1;

               loop
                  Sockets.Receive (Sock, Data);

                  if Data (1) = 13 then
                     Write_Data;
                     return False;
                  end if;

                  Buffer (Index) := Data (1);

                  if Index = Buffer'Last then
                     if Buffer = Signature then
                        return True;
                     else
                        Write_Data;
                        return False;
                     end if;
                  end if;

                  Index := Index + 1;

               end loop;
            end Check_EOF;

            ----------------------------
            -- End_Boundary_Signature --
            ----------------------------

            function End_Boundary_Signature
              return Streams.Stream_Element_Array
            is
               use Streams;
               End_Signature    : constant String := Start_Boundary;
               Stream_Signature : Stream_Element_Array
                 (Stream_Element_Offset (End_Signature'First)
                  .. Stream_Element_Offset (End_Signature'Last));
            begin
               for K in End_Signature'Range loop
                  Stream_Signature (Stream_Element_Offset (K))
                    := Stream_Element (Character'Pos (End_Signature (K)));
               end loop;
               return Stream_Signature;
            end End_Boundary_Signature;

         begin
            Streams.Stream_IO.Create
              (File,
               Streams.Stream_IO.Out_File,
               To_String (Server_Filename));

            Read_File : loop
               Sockets.Receive (Sock, Data);

               while Data (1) = 13 loop
                  exit Read_File when Check_EOF;
               end loop;

               Buffer (Index) := Data (1);
               Index := Index + 1;

               if Index > Buffer'Last then
                  Streams.Stream_IO.Write (File, Buffer);
                  Index := Buffer'First;

                  HTTP_Server.Slots.Mark_Data_Time_Stamp
                    (Protocol_Handler.Index);
               end if;
            end loop Read_File;

            if not (Index = Buffer'First) then
               Streams.Stream_IO.Write
                 (File, Buffer (Buffer'First .. Index - 1));
            end if;

            Streams.Stream_IO.Close (File);
         end Get_File_Data;

         ---------------------
         -- Target_Filename --
         ---------------------

         function Target_Filename (Filename : in String) return String is
            I   : constant Natural
              := Fixed.Index (Filename, Maps.To_Set ("/\"),
                              Going => Strings.Backward);
            UID : Natural;
            Upload_Path : constant String :=
               CNF.Upload_Directory (HTTP_Server.Properties);
         begin
            File_Upload_UID.Get (UID);

            if I = 0 then
               return Upload_Path
                 & Utils.Image (UID) & '.'
                 & Filename;
            else
               return Upload_Path
                 & Utils.Image (UID) & '.'
                 & Filename (I + 1 .. Filename'Last);
            end if;
         end Target_Filename;

      begin
         --  reach the boundary

         if Parse_Boundary then
            loop
               declare
                  Data : constant String := Sockets.Get_Line (Sock);
               begin
                  exit when Data = Start_Boundary;

                  if Data = End_Boundary then
                     --  this is the end of the multipart data
                     return;
                  end if;
               end;
            end loop;
         end if;

         --  Read file upload parameters

         declare
            Data : constant String := Sockets.Get_Line (Sock);
         begin
            if not Parse_Boundary then

               if Data = "--" then
                  --  Check if this is the end of the finish boundary string.
                  return;

               else
                  --  Data should be CR+LF here
                  declare
                     Data : constant String := Sockets.Get_Line (Sock);
                  begin
                     Is_File_Upload := Fixed.Index (Data, "filename=") /= 0;

                     Name
                       := To_Unbounded_String (Value_For ("name", Data));
                     Filename
                       := To_Unbounded_String (Value_For ("filename", Data));
                  end;
               end if;

            else
               Is_File_Upload := Fixed.Index (Data, "filename=") /= 0;

               Name     := To_Unbounded_String (Value_For ("name", Data));
               Filename := To_Unbounded_String (Value_For ("filename", Data));
            end if;
         end;

         --  Reach the data

         loop
            declare
               Data : constant String := Sockets.Get_Line (Sock);
            begin
               if Data = "" then
                  exit;
               else
                  Content_Type := To_Unbounded_String
                    (Data
                     (Messages.Content_Type_Token'Length + 1 .. Data'Last));
               end if;
            end;
         end loop;

         --  Read file/field data

         if Is_File_Upload then
            --  This part of the multipart message contains file data.

            --  Set Server_Filename, the name of the file in the local file
            --  sytstem.

            Server_Filename := To_Unbounded_String
              (Target_Filename (To_String (Filename)));

            if To_String (Filename) /= "" then
               AWS.Parameters.Set.Add
                 (P_List, To_String (Name), To_String (Server_Filename));

               Get_File_Data;

               File_Upload ("--" & Status.Multipart_Boundary (C_Stat),
                            "--" & Status.Multipart_Boundary (C_Stat) & "--",
                            False);
            else
               --  There is no file for this multipart, user did not enter
               --  something in the field.

               File_Upload ("--" & Status.Multipart_Boundary (C_Stat),
                            "--" & Status.Multipart_Boundary (C_Stat) & "--",
                            True);
            end if;

         else
            --  This part of the multipart message contains field value.

            declare
               Value : constant String := Sockets.Get_Line (Sock);
            begin
               AWS.Parameters.Set.Add (P_List, To_String (Name), Value);
            end;

            File_Upload ("--" & Status.Multipart_Boundary (C_Stat),
                         "--" & Status.Multipart_Boundary (C_Stat) & "--",
                         True);
         end if;

      end File_Upload;

      ---------------
      -- Value_For --
      ---------------

      function Value_For (Name : in String; Into : in String) return String is
         Pos   : constant Natural := Fixed.Index (Into, Name & '=');
         Start : constant Natural := Pos + Name'Length + 2;
      begin
         if Pos = 0 then
            return "";
         else
            return Into (Start
                         .. Fixed.Index (Into (Start .. Into'Last), """") - 1);
         end if;
      end Value_For;

   begin
      --  Is there something to read ?

      if Status.Content_Length (C_Stat) /= 0 then

         if Status.Method (C_Stat) = Status.POST
           and then Status.Content_Type (C_Stat) = MIME.Appl_Form_Data

         then
            --  Read data from the stream and convert it to a string as
            --  these are a POST form parameters.
            --  The body has the format: name1=value1;name2=value2...

            declare
               use Streams;

               Data : Stream_Element_Array
                 (1 .. Stream_Element_Offset (Status.Content_Length (C_Stat)));

               Char_Data : String (1 .. Data'Length);
               CDI       : Positive := Char_Data'First;
            begin
               Sockets.Receive (Sock, Data);

               AWS.Status.Set.Binary (C_Stat, Data);
               --  We record the message body as-is to be able to send it back
               --  to an hotplug module if needed.

               --  We then decode it and add the parameters read in the
               --  message body.

               for K in Data'Range loop
                  Char_Data (CDI) := Character'Val (Data (K));
                  CDI := CDI + 1;
               end loop;

               AWS.Parameters.Set.Add (P_List, Char_Data);
            end;

         elsif Status.Method (C_Stat) = Status.POST
           and then Status.Content_Type (C_Stat) = MIME.Multipart_Form_Data
         then
            --  This is a file upload.

            File_Upload ("--" & Status.Multipart_Boundary (C_Stat),
                         "--" & Status.Multipart_Boundary (C_Stat) & "--",
                         True);

         elsif Status.Method (C_Stat) = Status.POST
           and then Status.Is_SOAP (C_Stat)
         then
            --  This is a SOAP request, read and set the Payload XML message.
            declare
               use Streams;

               Data : Stream_Element_Array
                 (1
                  ..
                  Stream_Element_Offset (Status.Content_Length (C_Stat)));
            begin
               Sockets.Receive (Sock, Data);

               AWS.Status.Set.Payload (C_Stat, Translator.To_String (Data));
            end;

         else
            --  Let's suppose for now that all others content type data are
            --  binary data.

            declare
               use Streams;

               Data : Stream_Element_Array
                 (1
                  ..
                  Stream_Element_Offset (Status.Content_Length (C_Stat)));
            begin
               Sockets.Receive (Sock, Data);
               AWS.Status.Set.Binary (C_Stat, Data);
            end;

         end if;
      end if;
   end Get_Message_Data;

   ------------------------
   -- Get_Message_Header --
   ------------------------

   procedure Get_Message_Header is
      First_Line : Boolean := True;
   begin
      loop
         begin
            declare
               Data : constant String := Sockets.Get_Line (Sock);
            begin
               --  A request by the client has been received, do not abort
               --  until this request is handled.

               exit when Data = End_Of_Message;

               if First_Line then

                  HTTP_Server.Slots.Mark_Phase (Index, Client_Header);

                  Parse_Request_Line (Data);

                  First_Line := False;

               else
                  Parse (Data);
               end if;

            end;
         end;
      end loop;
   end Get_Message_Header;

   ------------------------
   -- Is_Valid_HTTP_Date --
   ------------------------

   function Is_Valid_HTTP_Date (HTTP_Date : in String) return Boolean is
      Mask   : constant String := "Aaa, 99 Aaa 9999 99:99:99 GMT";
      Offset : constant Integer := HTTP_Date'First - 1;
      --  Make sure the function works for inputs with 'First <> 1
      Result : Boolean := True;
   begin
      for I in Mask'Range loop
         Result := I + Offset in HTTP_Date'Range;

         exit when not Result;

         case Mask (I) is
            when 'A' =>
               Result := HTTP_Date (I + Offset) in 'A' .. 'Z';

            when 'a' =>
               Result := HTTP_Date (I + Offset) in 'a' .. 'z';

            when '9' =>
               Result := HTTP_Date (I + Offset) in '0' .. '9';

            when others =>
               Result := Mask (I) = HTTP_Date (I + Offset);
         end case;
      end loop;

      return Result;
   end Is_Valid_HTTP_Date;

   -----------
   -- Parse --
   -----------

   procedure Parse (Command : in String) is
   begin
      if Messages.Match (Command, Messages.Host_Token) then
         Status.Set.Host
           (C_Stat,
            Command (Messages.Host_Token'Length + 1 .. Command'Last));

      elsif Messages.Match (Command, Messages.Connection_Token) then
         Status.Set.Connection
           (C_Stat,
            Command (Messages.Connection_Token'Length + 1 .. Command'Last));

      elsif Messages.Match (Command, Messages.Content_Length_Token) then
         Status.Set.Content_Length
           (C_Stat,
            Natural'Value
            (Command (Messages.Content_Length_Token'Length + 1
                      .. Command'Last)));

      elsif Messages.Match (Command, Messages.Content_Type_Token) then
         declare
            Pos : constant Natural := Fixed.Index (Command, ";");
         begin
            if Pos = 0 then
               Status.Set.Content_Type
                 (C_Stat,
                  Command
                  (Messages.Content_Type_Token'Length + 1 .. Command'Last));
            else
               Status.Set.Content_Type
                 (C_Stat,
                  Command
                  (Messages.Content_Type_Token'Length + 1 .. Pos - 1));
               Status.Set.Multipart_Boundary
                 (C_Stat,
                  Command (Pos + 11 .. Command'Last));
            end if;
         end;

      elsif Messages.Match
        (Command, Messages.If_Modified_Since_Token)
      then
         Status.Set.If_Modified_Since
           (C_Stat,
            Command (Messages.If_Modified_Since_Token'Length + 1
                     .. Command'Last));

      elsif Messages.Match
        (Command, Messages.Authorization_Token)
      then
         Status.Set.Authorization
           (C_Stat,
            Command (Messages.Authorization_Token'Length + 1 .. Command'Last));

      elsif Messages.Match (Command, Messages.Cookie_Token) then
         declare
            use Ada.Strings;

            --  The expected Cookie line is:
            --  Cookie: ... AWS=<cookieID>[,;] ...

            Cookies : constant String
              := Command (Messages.Cookie_Token'Length + 1 .. Command'Last);

            AWS_Idx : constant Natural := Fixed.Index (Cookies, "AWS=");
            Last    : Natural;

         begin
            if AWS_Idx /= 0 then
               Last := Fixed.Index (Cookies (AWS_Idx .. Cookies'Last),
                                    Maps.To_Set (",;"));
               if Last = 0 then
                  Last := Cookies'Last;
               else
                  Last := Last - 1;
               end if;

               Status.Set.Session (C_Stat, Cookies (AWS_Idx + 4 .. Last));
            end if;
         end;

      elsif Messages.Match (Command, Messages.SOAPAction_Token) then
         Status.Set.SOAPAction
           (C_Stat,
            Command
              (Messages.SOAPAction_Token'Length + 2 .. Command'Last - 1));

      elsif Messages.Match (Command, Messages.User_Agent_Token) then
         Status.Set.User_Agent
           (C_Stat,
            Command
              (Messages.User_Agent_Token'Length + 1 .. Command'Last));

      elsif Messages.Match (Command, Messages.Referer_Token) then
         Status.Set.Referer
           (C_Stat,
            Command
              (Messages.Referer_Token'Length + 1 .. Command'Last));

      end if;
   end Parse;

   ------------------------
   -- Parse_Request_Line --
   ------------------------

   procedure Parse_Request_Line (Command : in String) is

      I1, I2 : Natural;
      --  Index of first space and second space

      I3 : Natural;
      --  Index of ? if present in the URI (means that there is some
      --  parameters)

      procedure Cut_Command;
      --  Parse Command and set I1, I2 and I3

      function Resource return String;
      pragma Inline (Resource);
      --  Returns first parameter. parameters are separated by spaces.

      function Parameters return String;
      --  Returns parameters if some where specified in the URI.

      function HTTP_Version return String;
      pragma Inline (HTTP_Version);
      --  Returns second parameter. parameters are separated by spaces.

      -----------------
      -- Cut_Command --
      -----------------

      procedure Cut_Command is
      begin
         I1  := Fixed.Index (Command, " ");
         I2  := Fixed.Index (Command (I1 + 1 .. Command'Last), " ", Backward);

         I3  := Fixed.Index (Command (I1 + 1 .. I2 - 1), "?");

         if I3 = 0 then
            --  Could be encoded ?

            I3  := Fixed.Index (Command (I1 + 1 .. I2 - 1), "%3f");

            if I3 = 0 then
               I3  := Fixed.Index (Command (I1 + 1 .. I2 - 1), "%3F");
            end if;
         end if;
      end Cut_Command;

      ------------------
      -- HTTP_Version --
      ------------------

      function HTTP_Version return String is
      begin
         return Command (I2 + 1 .. Command'Last);
      end HTTP_Version;

      ----------------
      -- Parameters --
      ----------------

      function Parameters return String is
      begin
         if I3 = 0 then
            return "";
         else
            if Command (I3) = '%' then
               return Command (I3 + 3 .. I2 - 1);
            else
               return Command (I3 + 1 .. I2 - 1);
            end if;
         end if;
      end Parameters;

      ---------
      -- URI --
      ---------

      function Resource return String is
      begin
         if I3 = 0 then
            return URL.Decode (Command (I1 + 1 .. I2 - 1));
         else
            return URL.Decode (Command (I1 + 1 .. I3 - 1));
         end if;
      end Resource;

   begin
      Cut_Command;

      if Messages.Match (Command, Messages.Get_Token) then
         Status.Set.Request (C_Stat, Status.GET, Resource, HTTP_Version);
         AWS.Parameters.Set.Add (P_List, Parameters);

      elsif Messages.Match (Command, Messages.Head_Token) then
         Status.Set.Request (C_Stat, Status.HEAD, Resource, HTTP_Version);

      elsif Messages.Match (Command, Messages.Post_Token) then
         Status.Set.Request (C_Stat, Status.POST, Resource, HTTP_Version);

      end if;
   end Parse_Request_Line;

   ---------------
   -- Send_File --
   ---------------

   procedure Send_File
     (Filename     : in String;
      File_Size    : in Natural;
      HTTP_Version : in String)
   is
      use type Streams.Stream_Element_Offset;

      procedure Send_File;
      --  Send file in one part

      procedure Send_File_Chunked;
      --  Send file in chunk (HTTP/1.1 only)

      File : Resources.File_Type;
      Last : Streams.Stream_Element_Offset;

      ---------------
      -- Send_File --
      ---------------

      procedure Send_File is

         use type Ada.Streams.Stream_Element_Offset;

         Buffer : Streams.Stream_Element_Array (1 .. 4_096);

      begin
         loop
            Resources.Read (File, Buffer, Last);

            exit when Last < Buffer'First;

            Sockets.Send (Sock, Buffer (1 .. Last));

            HTTP_Server.Slots.Mark_Data_Time_Stamp (Index);
         end loop;
      end Send_File;

      ---------------------
      -- Send_File_Chunk --
      ---------------------

      procedure Send_File_Chunked is

         Buffer : Streams.Stream_Element_Array (1 .. 1_024);

      begin
         loop
            Resources.Read (File, Buffer, Last);

            exit when Last < Buffer'First;

            Sockets.Put_Line (Sock, Utils.Hex (Positive (Last)));

            Sockets.Send (Sock, Buffer (1 .. Last));
            Sockets.New_Line (Sock);

            HTTP_Server.Slots.Mark_Data_Time_Stamp (Index);
         end loop;

         --  Last chunk

         Sockets.Put_Line (Sock, "0");
         Sockets.New_Line (Sock);
      end Send_File_Chunked;

   begin
      Resources.Open (File, Filename, "shared=no");

      Send_File_Time (Sock, Filename);

      Sockets.Put_Line (Sock, Messages.Content_Length (File_Size));

      if HTTP_Version = HTTP_10 then
         --  Terminate header

         Sockets.New_Line (Sock);

         Send_File;

      else
         --  Always use chunked transfer encoding method for HTTP/1.1 even if
         --  it also support standard method.
         --  ??? it could be better to use the standard method for small files
         --  (should be faster).

         --  Terminate header

         Sockets.Put_Line (Sock, "Transfer-Encoding: chunked");
         Sockets.New_Line (Sock);

         Send_File_Chunked;
      end if;

      Resources.Close (File);

   exception
      when Text_IO.Name_Error =>
         raise;

      when others =>
         Resources.Close (File);
         raise;
   end Send_File;

   --------------------
   -- Send_File_Time --
   --------------------

   procedure Send_File_Time
     (Sock     : in Sockets.Socket_FD'Class;
      Filename : in String) is
   begin
      Sockets.Put_Line
        (Sock, Messages.Last_Modified (Resources.File_Timestamp (Filename)));
   end Send_File_Time;

begin
   --  This new connection has been initialized because some data are
   --  beeing sent. We are by default using HTTP/1.1 persistent
   --  connection. We will exit this loop only if the client request
   --  so or if we time-out on waiting for a request.

   For_Every_Request : loop

      HTTP_Server.Slots.Mark_Phase (Index, Wait_For_Client);

      Status.Set.Reset (C_Stat);

      P_List := Status.Parameters (C_Stat);

      Parameters.Set.Case_Sensitive
        (P_List, Case_Sensitive_Parameters);

      HTTP_Server.Slots.Increment_Slot_Activity_Counter (Index);

      Get_Message_Header;

      HTTP_Server.Slots.Mark_Phase (Index, Client_Data);

      Get_Message_Data;

      Will_Close :=
        AWS.Messages.Match (Status.Connection (C_Stat), "close")
        or else HTTP_Server.Slots.N = 1
        or else (Status.HTTP_Version (C_Stat) = HTTP_10
                   and then
                 AWS.Messages.Does_Not_Match
                   (Status.Connection (C_Stat), "keep-alive"));

      Status.Set.Keep_Alive (C_Stat, not Will_Close);

      Status.Set.Parameters (C_Stat, P_List);

      HTTP_Server.Slots.Mark_Phase (Index, Server_Response);

      Answer_To_Client;

      --  Exit if connection has not the Keep-Alive status or we are working
      --  on HTTP/1.0 protocol or we have a single slot.

      exit For_Every_Request when Will_Close or else Socket_Taken;

   end loop For_Every_Request;

   --  Release memory for local objects

   Status.Set.Reset (C_Stat);

   Parameters.Set.Free (P_List);

exception
   when others =>
      Status.Set.Reset (C_Stat);
      Parameters.Set.Free (P_List);
      raise;
end Protocol_Handler;
