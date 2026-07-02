#!/bin/sh

# SPDX-License-Identifier: Apache-2.0
# Copyright © 2025 @p7r0x7 <maxibonnette@pm.me> All rights reserved.

#
#    VPXL's PP is an FFmpeg filterchain that optimizes the format and content of videos for encoding efficiency.
#    Only perceptible content is preserved (this filter is extremely conservative while remaining quite effective).
#    This filter should not be used on very low resolution content or prior to ultra high fidelity transcoding.
#

cli() {
    help() {
        printf '%s\n' \
            'Usage: pp.sh <video> [-yuv|-y4m|-mkv|-nut|-av1an] [-ffmpeg|ffprobe path]' \
            '  (order as applied) [-deint] [-trim start:end] [-crop w:h[:x:y]] [-scale w:h]' \
            '*) FFmpeg filters the first video in the file and its metadata, copying chapters.' \
            '*) Uncompressed frames or filter string are streamed to /dev/stdout.' \
            '*) For av1an, use "-f -vf $(pp video.mp4 -av1an ...)".'
        exit $1
    }
    [ $# -gt 0 ] || help 0; set -eu; umask 0022

    video="$1" format=yuv4mpegpipe deint='' trim='' crop='' scale='' ffmpeg='' ffprobe=''; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            -ffmpeg) [ $# -ge 2 ] || help 1; ffmpeg="$2 -v error -hwaccel auto"; shift 2 ;;
            -ffprobe) [ $# -ge 2 ] || help 1; ffprobe="$2 -v error"; shift 2 ;;
            -scale) [ $# -ge 2 ] || help 1; scale=$2; shift 2 ;;
            -trim) [ $# -ge 2 ] || help 1; trim=$2; shift 2 ;;
            -crop) [ $# -ge 2 ] || help 1; crop=$2; shift 2 ;;
            -av1an|-nut) format=${1#-}; shift ;;
            -y4m) format=yuv4mpegpipe; shift ;;
            -mkv) format=matroska; shift ;;
            -yuv) format=rawvideo; shift ;;
            -deint) eval 'deint=1' ;;
            *) help 1 ;;
        esac
    done

    [ -z "$ffmpeg" ] && ffmpeg="$(command -v ffmpeg) -v error -hwaccel auto"
    [ -z "$ffprobe" ] && {
        path="$(printf %s "$ffmpeg" | sed -E 's/^(([^\\ ]|\\ )+).*/\1/')"; path="${path%/*}/ffprobe"
        [ -f "$path" ] && ffprobe="$path -v error" || ffprobe="$(command -v ffprobe) -v error"
    }
    [ -f /tmp/ffmpeg_fmts.txt ] || $ffmpeg -pix_fmts >/tmp/ffmpeg_fmts.txt 2>&1 &
}

pp() {
    eval "$(
        $ffprobe -select_streams v:0 -of default=nw=1:nk=1 "$video" \
            -show_entries stream=width,height,pix_fmt,color_range,color_space,color_transfer,color_primaries,r_frame_rate | \
        awk 'NR==1 { printf "width=%s ", $0 }
            NR==2 { printf "height=%s ", $0 }
            NR==3 { printf "fmt=%s ",    $0 }
            NR==4 { printf "range=%s ",  $0 }
            NR==5 { printf "space=%s ",  $0 }
            NR==6 { printf "txfr=%s ",   $0 }
            NR==7 { printf "primes=%s ", $0 }
            NR==8 { printf "fps=%s\n",   $0 }'
    )"
    [ "$space$txfr$primes" = unknownunknownunknown ] && case $range in
        pc|full|jpeg) ;; *) space=bt709 txfr=bt709 primes=bt709 range=tv ;;
    esac

    case $fps in */*) ;; *) fps=$fps/1 ;; esac
    [ $deint = 1 ] && deint='bwdif=mode=0:deint=1,'
    [ -n "$crop" ] && crop="crop=$crop,"
    [ -n "$trim" ] && trim="trim=$trim,"

    if false; then
        decimate="mpdecimate=hi=256:lo=64:frac=0.1,"
    else
        decimate="
            freezedetect=n=0.2:d=0,
            metadata=add:lavfi.freezedetect.freeze_start:n/a,
            metadata=select:lavfi.freezedetect.freeze_start:n/a:same_str,"
    fi
    wait

    isalpha() {
        fmts=$(awk '$3 == 2 || $3 == 4 { printf "|%s", $2 }' /tmp/ffmpeg_fmts.txt)
        case "$fmt" in ${fmts#|}) return 0 ;; *) return 1 ;; esac
    }
    isalpha "$video" && fmt1=yuva444p16le fmt2=yuva420p10le || fmt1=yuv444p16le fmt2=yuv420p10le

    [ $height -lt 540 ] 

    filterchain="$(printf %s "
        $deint$trim$crop
        zscale=
            min=$space:tin=$txfr:pin=$primes:rin=$range:
            m=ictcp:t=smpte2084:p=bt2020:r=pc:
            f=lanczos:param_a=16,format=$fmt1,

        yaepblur=r=5:s=256,
        libplacebo=
            deband=1:deband_radius=8:deband_iterations=4:deband_threshold=4:deband_grain=0:
            extra_opts='downscaler=custom\\:downscaler_preset=lanczos\\:downscaler_radius=16':
            disable_linear=1:skip_aa=1:sigmoid=0:dithering=none:format=$fmt2,

        $decimate
        zscale=
            min=ictcp:tin=smpte2084:pin=bt2020:rin=pc:
            m=$space:t=$txfr:p=$primes:r=tv,
            fps=$fps:eof_action=pass,

        settb=${fps#*/}/${fps%%/*},setpts=PTS-STARTPTS" | tr -d '[:space:]') -fps_mode cfr -r $fps"

    if [ $format = av1an ]; then printf %s "$filterchain"; return; fi
    $ffmpeg -v error -i "$video" -map 0:v -vf $filterchain -c:v rawvideo -strict -1 -f $format -
}

cli "$@"; pp
