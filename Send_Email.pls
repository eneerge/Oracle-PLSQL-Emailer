CREATE OR REPLACE PROCEDURE send_email (
  p_email_subject IN VARCHAR2                           -- Subject of email
  ,p_email_to_csv IN CLOB                               -- CSV of receipients
  ,p_email_from IN VARCHAR2                             -- From, the email of the sender
  ,p_email_from_name IN VARCHAR2                        -- From, the name of the sender that shows up
  ,p_email_reply_to IN VARCHAR2                         -- ReplyTo, email address
  ,p_email_bcc_csv IN clob                              -- CSV of bccs
  ,p_email_cc_csv IN clob                               -- CSV of ccs
  ,p_email_priority IN INTEGER DEFAULT 3                -- Priority of the message, 3 is normal (can be null to default to 3)
  ,p_email_plaintext IN clob                            -- Plaintext version (can be null)
  ,p_email_html IN clob                                 -- Html version (can be null)
  ,p_attachment_filename IN VARCHAR2                    -- File name of attachment (can be null)
  ,p_attachment_filetype IN VARCHAR2                    -- Content-Type of the attachment. EG: Application/PDF, image/png, etc (can be null)
  ,p_attachment_data IN clob                            -- Base64 Encoded Data (can be null)
)
IS
 
/*
  Author: Evan Greene
  Date: 2016.04.22
  Description: Modularized email procedure so I didn't have to recreate the wheel each time.  Written from scratch.
 
  Notes:
  The CSV input values should not be enclosed by double quotes.
 
  Google - Throttles messages.  Send maximum of :
  60/min
  3,600/hour
  86,400/day
 
  How to attach?
  You need base64 of the file.
 
  If filename and filetype are specified, but no data is specified, then attachment will be skipped.
*/
 
  PRIORITY_HIGH           CONSTANT INTEGER := 1;
  PRIORITY_NORMAL         CONSTANT INTEGER := 3;
  PRIORITY_LOW            CONSTANT INTEGER := 5;
 
  -- Email construct
  l_email_to             CLOB                  := p_email_to_csv;
  l_email_cc             CLOB                  := p_email_cc_csv;
  l_email_bcc            CLOB                  := p_email_bcc_csv;
  l_email_from           VARCHAR2(100)         := p_email_from;
  l_email_from_name      VARCHAR2(100)         := p_email_from_name;
  l_email_reply_to       VARCHAR2(100)         := p_email_reply_to;
  l_email_subject        VARCHAR2(100)         := p_email_subject;
  l_email_priority       INTEGER               := p_email_priority;
  l_email_plaintext      CLOB                  := p_email_plaintext;
  l_email_html           CLOB                  := p_email_html;
  l_attachment_filename  VARCHAR2(100)         := p_attachment_filename;
  l_attachment_filetype  VARCHAR2(100)         := p_attachment_filetype;
  l_attachment_data      CLOB                  := p_attachment_data;
 
  l_smtp_hostname        VARCHAR2(50)          :=  'smtp.server.com';
  l_smtp_portnum         VARCHAR2(50)          := 25;
 
  -- Basic Anatomy: Outer Boundary [ Inner Boundary [ HTML, Plain Text ] , Attachment ]
  l_boundary_outer       VARCHAR2(32)         DEFAULT SYS_GUID();  -- Outer boundary that will house inner boundary and the attachments
  l_boundary_inner       VARCHAR2(32)         DEFAULT SYS_GUID();  -- Inner boundary that will hold html/plaintext nested inside outer boundary
 
  l_connection           UTL_SMTP.connection;
  l_body                 CLOB                  := EMPTY_CLOB;
  l_offset               NUMBER;
  l_amount               NUMBER                := 1900; -- Chunk size of message to be sent to server
  l_temp                 VARCHAR2 (32767)      DEFAULT NULL;
 
  --
  l_hasPlainText         BOOLEAN               := FALSE;
  l_hasHtml              BOOLEAN               := FALSE;
  l_hasAttachment        BOOLEAN               := FALSE;
 
  BEGIN
   -- Cleanse input
   l_email_from := REPLACE(l_email_from,' ');
   
   l_email_to := REPLACE(l_email_to,' ');
   l_email_to := LTRIM(RTRIM(l_email_to,','),',');
   
   l_email_cc := REPLACE(l_email_cc,' ');
   l_email_cc := LTRIM(RTRIM(l_email_cc,','),',');
   
   l_email_bcc := REPLACE(l_email_bcc,' ');
   l_email_bcc := LTRIM(RTRIM(l_email_bcc,','),',');
 
 
   IF LENGTH(l_email_plaintext) > 0 THEN
     l_hasPlainText := TRUE;
   END IF;
   
   IF LENGTH(l_email_html) > 0 THEN
     l_hasHtml := TRUE;
   END IF;
   
   IF LENGTH(l_attachment_data) > 0 THEN
     l_hasAttachment := TRUE;
   END IF;
 
    -- Lets make sure theres something to send
    IF l_hasPlainText OR l_hasHtml OR l_hasAttachment
    THEN
   
      -- ##########################
      -- ## Construct Email
      -- Headers
      l_temp := l_temp || 'MIME-Version: 1.0' || UTL_TCP.crlf;
      l_temp := l_temp || 'To: ' || l_email_to || UTL_TCP.crlf;
     
      IF LENGTH(l_email_cc) > 0 THEN
        l_temp := l_temp || 'cc: ' || l_email_cc || UTL_TCP.crlf;
      END IF;
      IF LENGTH(l_email_bcc) > 0 THEN
        l_temp := l_temp || 'bcc: ' || l_email_bcc || UTL_TCP.crlf;
      END IF;
      l_temp := l_temp || 'From: "' || l_email_from_name || '" <' || l_email_from || '>' || UTL_TCP.crlf;
      l_temp := l_temp || 'Subject: ' || l_email_subject || UTL_TCP.crlf;
     
      IF LENGTH(l_email_reply_to) > 0 THEN
        l_temp := l_temp || 'Reply-To: ' || l_email_reply_to || UTL_TCP.crlf;
        ELSE
          l_temp := l_temp || 'Reply-To: ' || l_email_from || UTL_TCP.crlf;
      END IF;
     
      l_temp := l_temp || 'X-Priority: ' || l_email_priority || UTL_TCP.crlf;
      --l_temp := l_temp || 'Disposition-Notification-To: ' || l_from || utl_tcp.crlf; -- request receipt
 
      -- Define Outer boundary
      l_temp := l_temp || 'Content-Type: multipart/mixed; boundary="' || l_boundary_outer || '"';
      l_temp := l_temp || UTL_TCP.crlf || UTL_TCP.crlf;
     
      -- Start outer boundary
      l_temp := l_temp || '--' || l_boundary_outer || UTL_TCP.crlf;
 
      -- Lets go ahead and create the email clob that will be sent to the server and write the current headers to it
      DBMS_LOB.createtemporary(l_body, FALSE, 10);
      DBMS_LOB.WRITE(l_body, LENGTH (l_temp), 1, l_temp);
     
      -- If theres html or plain text, then we need to include inner boundary
      IF l_hasPlainText OR l_hasHtml THEN
        -- Define Inner Boundary
        l_temp := l_temp || 'Content-Type: multipart/alternative; boundary="' || l_boundary_inner || '"' || UTL_TCP.crlf;
        l_temp := l_temp || 'MIME-Version: 1.0';
        l_temp := l_temp || UTL_TCP.crlf || UTL_TCP.crlf;
        DBMS_LOB.WRITE(l_body, LENGTH (l_temp), 1, l_temp);
       
        -- Time for Inner Boundary
        -- The version that shows up last is the one prioritized by the client, so lets do plaintext first
        -- to make it last priority and html last to make it first priority
 
        -- Only include plain text if it was provided
        IF l_hasPlainText THEN
          l_temp := '--' || l_boundary_inner || UTL_TCP.crlf;
          l_temp := l_temp || 'Content-Type: text/plain; charset=utf-8' || UTL_TCP.CRLF; -- NOTE: utf isn't actually supported by 7-bit, will need to update if we start sending real utf characters.
          l_temp := l_temp || 'Content-Transfer-Encoding: 7bit';
          l_temp := l_temp || UTL_TCP.crlf || UTL_TCP.crlf;
 
          -- Go ahead and write to email clob
          DBMS_LOB.writeappend(l_body, LENGTH (l_temp), l_temp);
 
          -- Now, write the plain text body and the ending blank line to the email clob if plaintext exists
          DBMS_LOB.append(l_body, l_email_plaintext);
          DBMS_LOB.writeappend(l_body, LENGTH (UTL_TCP.crlf), UTL_TCP.CRLF);
        END IF;
 
        -- Now for the html section if exists
        IF l_hasHtml THEN
          l_temp := '--' || l_boundary_inner || UTL_TCP.crlf;
          l_temp := l_temp || 'Content-Type: text/html; charset=utf-8' || UTL_TCP.CRLF;
          l_temp := l_temp || 'Content-Transfer-Encoding: 7bit';
          l_temp := l_temp || UTL_TCP.crlf || UTL_TCP.crlf;
         
          -- Write the headers for html body and then the html body itself and then the ending line
          DBMS_LOB.writeappend(l_body, LENGTH (l_temp), l_temp);
          DBMS_LOB.append(l_body, l_email_html);
          DBMS_LOB.writeappend(l_body, LENGTH (UTL_TCP.crlf), UTL_TCP.CRLF);
        END IF;
       
        -- PlainText and HTML done, time to end the inner boundary
        l_temp := '--' || l_boundary_inner || '--';
        l_temp := l_temp || UTL_TCP.crlf || UTL_TCP.crlf;
        DBMS_LOB.writeappend(l_body, LENGTH (l_temp), l_temp);
       
      -- End inner boundary / end plaintext and html
      END IF;
 
      -- Message section done, now for the attachment section (if one exists)
      IF l_hasAttachment THEN
        l_temp := '--' || l_boundary_outer || UTL_TCP.crlf;
        l_temp := l_temp || 'Content-Type: ' || l_attachment_filetype || '; name="' || l_attachment_filename || '"' || UTL_TCP.CRLF;
       
        IF l_attachment_filetype <> 'text/html' AND l_attachment_filetype <> 'text/plain' THEN
          l_temp := l_temp || 'Content-Transfer-Encoding: base64' || UTL_TCP.CRLF;
        END IF;
        l_temp := l_temp || 'Content-Disposition: attachment';
        l_temp := l_temp || UTL_TCP.crlf || UTL_TCP.crlf;
     
        -- Write headers
        DBMS_LOB.writeappend(l_body, LENGTH (l_temp), l_temp);
       
        -- Write Contents of base64 encoded attachment
        DBMS_LOB.append(l_body, l_attachment_data);
        DBMS_LOB.writeappend(l_body, LENGTH (UTL_TCP.crlf), UTL_TCP.CRLF);      
      END IF;
     
      -- Attachment section done, lets close the outer boundary and we'll be ready to communicate with server
      l_temp := '--' || l_boundary_outer || '--';
      l_temp := l_temp || UTL_TCP.crlf || UTL_TCP.crlf;
      DBMS_LOB.writeappend(l_body, LENGTH (l_temp), l_temp);
     
      /*
      DEBUG
         Uncomment below code to show contents of email clob before sending
         NOTE: Currently doesn't work when including an attachment, because that will likely make it go over 32k limit of dbms_output package.
         To fix this issue, loop through l_body and .put a substr of l_body until all is read.  Max number of buffer is 32767 bytes.
         Just using substr below we can work around that limitation and we don't really want to see the raw bytes of the attachment anyway.
      */
      --dbms_output.put(substr(l_body,1,32767)); --
     
      -- ##########################
      -- ## Create SMTP Connection
      l_connection := UTL_SMTP.open_connection (l_smtp_hostname, l_smtp_portnum);
      UTL_SMTP.helo (l_connection, l_smtp_hostname);
      UTL_SMTP.mail (l_connection, l_email_from);
     
      -- Find each recipient in TO LINE
      l_temp := l_email_to;
      IF LENGTH(l_temp) > 0 THEN
        LOOP
          -- Get pos of first comma
          l_offset := INSTR(l_temp,',');
 
          IF l_offset = 0 THEN
            --dbms_output.put_line(l_temp); -- just for debugging
            UTL_SMTP.rcpt(l_connection, l_temp);
            EXIT;
             
          ELSE
            UTL_SMTP.rcpt(l_connection, SUBSTR(l_temp,1,l_offset));
           --dbms_output.put_line(substr(l_temp,1,l_offset-1));  -- just for debugging
            l_temp := SUBSTR(l_temp,l_offset+1);
          END IF;
        END LOOP;
      END IF;
     
      -- Find each recipient in CC LINE
      l_temp := l_email_cc;
      IF LENGTH(l_temp) > 0 THEN
        LOOP
          -- Get pos of first comma
          l_offset := INSTR(l_temp,',');
 
          IF l_offset = 0 THEN
            --dbms_output.put_line(l_temp); -- just for debugging
            UTL_SMTP.rcpt(l_connection, l_temp);
            EXIT;
             
          ELSE
            UTL_SMTP.rcpt(l_connection, SUBSTR(l_temp,1,l_offset));
           --dbms_output.put_line(substr(l_temp,1,l_offset-1));  -- just for debugging
            l_temp := SUBSTR(l_temp,l_offset+1);
          END IF;
        END LOOP;
      END IF;
     
      -- Find each recipient in BCC LINE
      l_temp := l_email_bcc;
      IF LENGTH(l_temp) > 0 THEN
        LOOP
          -- Get pos of first comma
          l_offset := INSTR(l_temp,',');
 
          IF l_offset = 0 THEN
            --dbms_output.put_line(l_temp); -- just for debugging
            UTL_SMTP.rcpt(l_connection, l_temp);
            EXIT;
             
          ELSE
            UTL_SMTP.rcpt(l_connection, SUBSTR(l_temp,1,l_offset));
           --dbms_output.put_line(substr(l_temp,1,l_offset-1));  -- just for debugging
            l_temp := SUBSTR(l_temp,l_offset+1);
          END IF;
        END LOOP;
      END IF;
     
      -- Send the email in l_amount byte chunks to UTL_SMTP
      l_offset := 1;
      UTL_SMTP.open_data (l_connection);
 
      WHILE l_offset < DBMS_LOB.getlength (l_body)
      LOOP
        UTL_SMTP.write_data (l_connection,
                              DBMS_LOB.SUBSTR (
                                l_body
                                ,l_amount
                                ,l_offset
                              )
                            );
        l_offset := l_offset + l_amount;
        l_amount := LEAST (l_amount, DBMS_LOB.getlength (l_body) - l_amount);
      END LOOP;
 
      UTL_SMTP.close_data (l_connection);
      UTL_SMTP.quit (l_connection);
      DBMS_LOB.freetemporary (l_body);
     
    -- End there was data to send
    END IF;
  END
;
