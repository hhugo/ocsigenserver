(* Ocsigen
 * http://www.ocsigen.org
 * Module revproxy.ml
 * Copyright (C) 2007 Vincent Balat
 * Laboratoire PPS - CNRS Universit� Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception; 
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(** Reverse proxy for Ocsigen *)

(* To compile it:
ocamlfind ocamlc  -thread -package netstring,ocsigen -c revproxy.ml

Then load it dynamically from Ocsigen's config file:
   <extension module=".../revproxy.cmo"/>

*)

open Lwt
open Extensions
open Simplexmlparser



(*****************************************************************************)
(* The table of redirections for each virtual server                         *)
type redir =
    { regexp: Netstring_pcre.regexp;
      https: bool;
      server:string;
      port: string;
      uri: string}



(*****************************************************************************)
let rec parse_global_config = function
  | [] -> ()
  | _ -> raise (Error_in_config_file 
                  ("Unexpected content inside revproxy config"))

let _ = parse_global_config (Extensions.get_config ())




(*****************************************************************************)
(* Finding redirections *)

let find_redirection r path =
  let path = Ocsimisc.string_of_url_path path in
  match Netstring_pcre.string_match r.regexp path 0 with
  | None -> raise Ocsigen_404
  | Some _ -> (* Matching regexp found! *)
      (r.https,
       Netstring_pcre.global_replace r.regexp r.server path,
       int_of_string 
         (Netstring_pcre.global_replace r.regexp r.port path),
       Netstring_pcre.global_replace r.regexp r.uri path)




(*****************************************************************************)
(** Function to be called at the beginning of the initialisation phase 
    of the server (actually each time the config file is reloaded) *)
let start_init () =
  ()

(** Function to be called at the end of the initialisation phase *)
let end_init () =
  ()



(*****************************************************************************)
(** The function that will generate the pages from the request. *)
exception Bad_answer_from_http_server

let gen dir charset ri =
  catch
    (* Is it a redirection? *)
    (fun () ->
      Messages.debug ("--Revproxy: Is it a redirection?");
      let (https, host, port, uri) = find_redirection dir ri.ri_sub_path in
      let uri = "/"^uri in
      Messages.debug ("--Revproxy: YES! Redirection to "^
                      (if https then "https://" else "http://")^host^":"^
                      (string_of_int port)^uri);
      Preemptive.detach Unix.gethostbyname host >>= fun host_entry ->
      Http_client.raw_request 
        ~headers:ri.ri_http_frame.Http_frame.header.Http_frame.Http_header.headers
        ~https ~port 
        ?content:ri.ri_http_frame.Http_frame.content
        ~http_method:ri.ri_method
        ~host ~inet_addr:host_entry.Unix.h_addr_list.(0)
        ~uri ()
        >>= fun http_frame ->
      let headers = 
        http_frame.Http_frame.header.Http_frame.Http_header.headers 
      in
      let code = 
        match http_frame.Http_frame.header.Http_frame.Http_header.mode with
        | Http_frame.Http_header.Answer code -> code
        | _ -> raise Bad_answer_from_http_server
      in
      return
        (Ext_found
           {res_cookies=[];
	    res_send_page=
            (fun ?filter ?cookies waiter ~clientproto ?mode 
                ?code ?etag ~keep_alive
                ?last_modified ?location ~head ?headers ?charset s ->
                  match http_frame.Http_frame.content with
                  | None ->
                      Predefined_senders.send_empty
                        ~content:()
                        ?filter
                        ?cookies
                        waiter 
                        ~clientproto
                        ?mode
                        ?code
                        ?etag ~keep_alive
                        ?last_modified 
                        ~head ?headers ?charset s
                  | Some stream ->
                      Predefined_senders.send_stream
                        ~content:stream
                        ?filter
                        ?cookies
                        waiter 
                        ~clientproto
                        ?mode
                        ?code
                        ?etag ~keep_alive
                        ?last_modified 
                        ~head ?headers ?charset s);
	    res_headers=headers;
	    res_code= Some code;
	    res_lastmodified= None;
	    res_etag= None;
	    res_charset= None;
            res_filter=None})
    )
    (function 
      | Extensions.Ocsigen_404 -> return (Ext_not_found Ocsigen_404)
      | e -> fail e)





(*****************************************************************************)
(** Configuration for each site.
    These tags are inside <site ...>...</site> in the config file.
        
   For example:
   <site dir="">
     <revproxy regexp="" dest="" />
   </extension>

 *)

let parse_config path = function
  | Element ("revproxy", atts, []) -> 
      let rec parse_attrs ((r, s, prot, port, u) as res) = function
        | [] -> res
        | ("regexp", regexp)::l when r = None ->
            parse_attrs
              (Some (Netstring_pcre.regexp ("/"^regexp)), s, prot, port, u)
              l
        | ("protocol", protocol)::l 
          when prot = None && String.lowercase protocol = "http" -> 
            parse_attrs
              (r, s, Some false, port, u)
              l
        | ("protocol", protocol)::l 
          when prot = None && String.lowercase protocol = "https" -> 
            parse_attrs
              (r, s, Some true, port, u)
              l
        | ("server", server)::l when s = None ->
            parse_attrs
              (r, Some server, prot, port, u)
              l
        | ("uri", uri)::l when u = None ->
            parse_attrs
              (r, s, prot, port, Some uri)
              l
        | ("port", p)::l when port = None ->
            parse_attrs
              (r, s, prot, Some p, u)
              l
        | _ -> raise (Error_in_config_file "Wrong attribute for <revproxy>")
        in
        let dir =
          match parse_attrs (None, None, None, None, None) atts with
          | (None, _, _, _, _) -> raise (Error_in_config_file "Missing attribute regexp for <revproxy>")
          | (_, None, _, _, _) -> raise (Error_in_config_file "Missing attribute server for <revproxy>")
          | (_, _, _, _, None) -> raise (Error_in_config_file "Missing attribute uri for <revproxy>")
          | (Some r, Some s, None, port, Some u) -> 
              {
               regexp=r;
               server=s;
               https=false;
               port=(match port with
               | Some p -> p
               | None -> "80");
               uri=u;
             }
          | (Some r, Some s, Some prot, port, Some u) -> 
              {
               regexp=r;
               server=s;
               https=prot;
               port=(match port with
               | Some p -> p
               | None -> if prot then "443" else "80");
               uri=u;
             }
        in
        Page_gen (gen dir)
  | Element (t, _, _) -> raise (Bad_config_tag_for_extension t)
  | _ -> raise (Error_in_config_file "(revproxy extension) Bad data")





(*****************************************************************************)
(** Registration of the extension *)
let _ = register_extension (* takes a quadruple *)
    ((fun hostpattern path charset -> parse_config path),
     start_init,
     end_init,
     raise)
