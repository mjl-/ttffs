implement Ttffs;

# serve (over styx) ttf's as inferno/plan 9 (sub)fonts in arbitrary sizes.
# fonts and subfonts are not listed in the directory, but can be walked to.
# the font and subfont files are generated on the fly.
# subfonts contain at most 128 glyphs.
# at first read of a font, it is parsed and its glyph ranges determined.
#
# for each font file ("name.ttf") the following files are served:
# name.<size>.font
# name.<size>.<index>
#
# the second form are subfonts, index starts at 1.  index 1 always has the single char 0.

include "sys.m";
	sys: Sys;
	sprint: import sys;
include "draw.m";
	draw: Draw;
	Display, Rect, Point, Image: import draw;
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop: import styxservers;
	nametree: Nametree;
	Tree: import nametree;
	Enotfound: import styxservers;
include "freetype.m";
	ft: Freetype;
	Face, Glyph: import ft;
include "readdir.m";
	readdir: Readdir;
include "tables.m";
	tables: Tables;
	Table, Strhash: import tables;

Ttffs: module {
	init:	fn(nil: ref Draw->Context, args: list of string);
};

dflag: int;
wdpi := hdpi := 96;
fontpath: string;

disp: ref Display;
srv: ref Styxserver;

idgen := 1;

Ttf: adt {
	name:	string;
	f:	ref Face;
	path:	string;
	ranges:	array of ref (int, int);	# sorted, start-end inclusive
	sizes:	cyclic ref Table[cyclic ref Ttfsize];
};

Ttfsize: adt {
	id:	int;	# qid.path.  subfonts are id+1+i.
	ttf:	ref Ttf;
	range:	int;	# index for Ttf.ranges.  0 is .font, 1 is first in range
	size:	int;
	dat:	array of byte;
};

fonts: ref Strhash[ref Ttf]; # name
ttfsizes: ref Table[ref Ttfsize]; # qid.path


init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	disp = ctxt.display;
	if(disp == nil)
		fail("no display");
	draw = load Draw Draw->PATH;
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	ft = load Freetype Freetype->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	styxservers->init(styx);
	nametree = load Nametree Nametree->PATH;
	nametree->init();
	readdir = load Readdir Readdir->PATH;
	tables = load Tables Tables->PATH;

	sys->pctl(Sys->NEWPGRP|Sys->FORKNS, nil);

	arg->init(args);
	arg->setusage(arg->progname()+" [-d] [-r xdpi ydpi] fontpath");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dflag++;
		'r' =>	wdpi = int arg->arg();
			hdpi = int arg->arg();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	fontpath = hd args;

	fonts = fonts.new(11, nil);
	ttfsizes = ttfsizes.new(11, nil);

	navc := chan of ref Navop;
	spawn navigator(navc);
	msgc: chan of ref Tmsg;
	(msgc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(navc), big 0);
	main(msgc);
	killgrp(pid());
}

openttf(path, name: string): (ref Ttf, string)
{
	fc := ft->newface(path, 0);
	if(fc == nil)
		return (nil, sprint("%r"));

	say(sprint("have face, nfaces=%d index=%d style=%d height=%d ascent=%d familyname=%q stylename=%q",
		fc.nfaces, fc.index, fc.style, fc.height, fc.ascent, fc.familyname, fc.stylename));

	ranges := list of {ref (0, 0)};
	max := 64*1024;
	i := 1;
	while(i < max) {
		for(; i < max && !fc.haschar(i); i++)
			{}
		s := i;
		for(; i < max && fc.haschar(i); i++)
			{}
		e := i;
		while(s < e) {
			n := e-s;
			if(n > 128)
				n = 128;
			if(dflag > 1) say(sprint("range %d-%d", s, s+n-1));
			ranges = ref (s, s+n-1)::ranges;
			s += n;
		}
	}

	f := ref Ttf(name, fc, path, l2a(rev(ranges)), nil);
	f.sizes = f.sizes.new(11, nil);
	return (f, nil);
}

mkname(f: ref Ttfsize): string
{
	if(f.range == 0)
		return sprint("%s.%d.font", f.ttf.name, f.size);
	return sprint("%s.%d.%d", f.ttf.name, f.size, f.range);
}

mkdat(f: ref Ttfsize): array of byte
{
	if(f.dat == nil) {
		if(f.range == 0)
			f.dat = mkfont(f);
		else
			f.dat = mksubfont(f);
	}
	return f.dat;
}

mkfont(f: ref Ttfsize): array of byte
{
	fc := f.ttf.f;
	fc.setcharsize(f.size<<6, wdpi, hdpi);
	s := sprint("%d %d\n", fc.height, fc.ascent);
	for(i := 0; i < len f.ttf.ranges; i++) {
		(a, b) := *f.ttf.ranges[i];
		s += sprint("0x%04X\t0x%04X\t%q\n", a, b, sprint("%s.%d.%d", f.ttf.name, f.size, i+1));
	}
	return array of byte s;
}

mksubfont(f: ref Ttfsize): array of byte
{
	(s, l) := *f.ttf.ranges[f.range-1];
	fc := f.ttf.f;
	fc.setcharsize(f.size<<6, wdpi, hdpi);

	imgs := array[l+1-s] of ref Image;
	n := l+1-s;
	width := 0;
	left := array[len imgs+1] of {* => 0};
	advance := array[len imgs+1] of {* => 0};
	for(i := 0; i < n; i++) {
		c := s+i;
		g := fc.loadglyph(c);
		if(g == nil)
			fail(sprint("no glyph for %c (%#x)", c, c));
		say(sprint("glyph %#x, width=%d height=%d top=%d left=%d advance=%d,%d", c, g.width, g.height, g.top, g.left, g.advance.x>>6, g.advance.y>>6));
		r := Rect((0,0), (g.width, fc.height));
		img := imgs[i] = disp.newimage(r, Draw->GREY8, 0, Draw->Black);
		gr: Rect;
		gr.min = (0,fc.ascent-g.top);
		gr.max = gr.min.add((g.width, g.height));
		img.writepixels(gr, g.bitmap);

		width += g.width;
		left[i] = g.left;
		advance[i] = g.advance.x>>6;
	}

	oimghdr := 0;
	obuf := oimghdr + 5*12;
	osubfhdr := obuf + fc.height*width;
	ochars := osubfhdr + 3*12;
	oend := ochars + (len imgs+1)*6;
	buf := array[oend] of byte;

	fontr := Rect((0,0), (width,fc.height));
	fontimg := disp.newimage(fontr, Draw->GREY8, 0, Draw->Black);
	buf[oimghdr:] = sys->aprint("%11s %11d %11d %11d %11d ", "k8", 0, 0, fontr.max.x, fontr.max.y);
	x := 0;
	buf[osubfhdr:] = sys->aprint("%11d %11d %11d ", len imgs, fc.height, fc.ascent);
	o := ochars;
	for(i = 0; i < len imgs+1; i++) {
		if(i < len imgs)
			img := imgs[i];
		buf[o++] = byte (x>>0);
		buf[o++] = byte (x>>8);
		buf[o++] = byte 0;  # top
		buf[o++] = byte fc.height;  # bottom
		buf[o++] = byte left[i];  # left
		if(img == nil) {
			buf[o++] = byte 0;  # width
			break;
		}
		buf[o++] = byte advance[i];  # width
		r := fontr;
		r.min.x = x;
		fontimg.draw(r, disp.white, img, Point(0,0));
		x += img.r.dx();
	}
	if(o != len buf)
		raise "bad pack";
	r := fontimg.readpixels(fontimg.r, buf[obuf:]);
	if(r != osubfhdr-obuf)
		fail(sprint("readpixels, got %d, expected %d: %r", r, osubfhdr-obuf));
	return buf;
}

main(msgc: chan of ref Tmsg)
{
	for(;;) {
		mm := <-msgc;
		if(mm == nil)
			return;
		pick m := mm {
		Readerror =>
			return warn("read: "+m.error);
		* =>
			handle(mm);
		}
	}
}

navigator(navc: chan of ref Navop)
{
	for(;;)
		navigate(<-navc);
}

navreply(op: ref Navop, d: ref Sys->Dir, err: string)
{
	op.reply <-= (d, err);
}

navigate(op: ref Navop)
{
	pick x := op {
	Stat =>
		if(x.path == big 0)
			return navreply(x, ref dir(".", 8r555|Sys->DMDIR, big 0, 0), nil);
		f := ttfsizes.find(int x.path);
		if(f == nil)
			return navreply(x, nil, sprint("missing Ttfsize for qid.path %bd/%#bx", x.path, x.path));
		d := ref dir(mkname(f), 8r444, x.path, len mkdat(f));
		navreply(x, d, nil);
	Walk =>
		if(x.name == "..")
			return navreply(x, ref dir(".", 8r555|Sys->DMDIR, big 0, 0), nil);
		if(x.path != big 0)
			return navreply(x, nil, Enotfound);

		name, size, suf: string;
		s := x.name;
		(name, s) = str->splitstrl(s, ".");
		if(s != nil)
			(size, s) = str->splitstrl(s[1:], ".");
		if(s != nil) {
			(suf, s) = str->splitstrl(s[1:], ".");
			if(s != nil)
				return navreply(x, nil, Enotfound);
		} else
			return navreply(x, nil, Enotfound);

		# format is good
		f := fonts.find(name);
		if(f == nil) {
			p := sprint("%s/%s.ttf", fontpath, name);
			(ttf, err) := openttf(p, name);
			if(err != nil)
				return navreply(x, nil, err);
			fonts.add(ttf.name, ttf);
			f = ttf;
		}
		(sz, rem) := str->toint(size, 10);
		if(rem != nil)
			return navreply(x, nil, Enotfound);
		if(sz <= 1)
			return navreply(x, nil, "requested font size too small");

		r := 0;
		if(suf != "font") {
			(r, rem) = str->toint(suf, 10);
			if(rem != nil || r <= 0 || r > len f.ranges)
				return navreply(x, nil, Enotfound);
		}

		say(sprint("walk, r %d", r));

		xf := f.sizes.find(sz);
		if(xf == nil) {
			xf = ref Ttfsize(idgen++, f, 0, sz, nil);
			ttfsizes.add(xf.id, xf);
			for(i := 0; i < len f.ranges; i++) {
				sf := ref Ttfsize(idgen++, f, 1+i, sz, nil);
				ttfsizes.add(sf.id, sf);
			}
			f.sizes.add(sz, xf);
		}
		ff := ttfsizes.find(xf.id+r);
		navreply(x, ref dir(x.name, 8r444, big ff.id, len mkdat(ff)), nil);

	Readdir =>
		navreply(x, nil, nil);
	}
}

handle(mm: ref Tmsg)
{
	pick m := mm {
	Read =>
		ff := srv.getfid(m.fid);
		if(ff == nil || ff.path == big 0 || !ff.isopen)
			break;

		path := int ff.path;
		f := ttfsizes.find(path);
		if(f == nil)
			srv.reply(ref Rmsg.Error(m.tag, "ttfsize not found?"));
		else
			srv.reply(styxservers->readbytes(m, mkdat(f)));
		return;
	}
	srv.default(mm);
}

dir(name: string, mode: int, path: big, length: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "ttffs";
	d.qid.path = big path;
	d.qid.qtype = Sys->QTFILE;
	if(mode&Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mtime = d.atime = 0;
	d.mode = mode;
	d.length = big length;
	return d;
}

suffix(suf, s: string): int
{
	return len s >= len suf && suf == s[len s-len suf:];
}

pid(): int
{
	return sys->pctl(0, nil);
}

killgrp(pid: int)
{
	sys->fprint(sys->open(sprint("/prog/%d/ctl", pid), Sys->OWRITE), "killgrp");
}

rev[T](l: list of T): list of T
{
	r: list of T;
	for(; l != nil; l = tl l)
		r = hd l::r;
	return r;
}

l2a[T](l: list of T): array of T
{
	a := array[len l] of T;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

warn(s: string)
{
	sys->fprint(sys->fildes(2), "%s\n", s);
}

say(s: string)
{
	if(dflag)
		warn(s);
}

fail(s: string)
{
	warn(s);
	raise "fail:"+s;
}
